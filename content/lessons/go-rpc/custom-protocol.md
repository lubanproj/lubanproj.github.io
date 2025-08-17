---
title: "第七章：自定义协议实现"
date: 2020-02-07T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-7"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/custom-protocol/"
---

### 一、协议选型

协议是客户端和服务端之间对话的 “语言” ，是客户端和服务端双方必须共同遵从的一组约定。如怎么样建立连接、怎么样互相识别等。

之前 RPC 原理的章节说到了，关于 client 和 server 之间进行传输的协议选型，这里有两种方案。

第一种是直接使用业内比较成熟的协议，比如 http 协议。但是 http 是文本型协议，传输效率太低，所以可以考虑 http2 协议，http2 协议是二进制协议，传输效率远远超过 http1.x，例如 grpc 就是基于 http2 协议去做的协议定制，将 grpc 的一些协议信息封装在 http2 的帧信息里面进行传递。详细可参考：[grpc 协议](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)

第二种是自定义一套二进制私有协议。这套私有协议专门为了这款 RPC 框架的 client 和 server 进行通信而生，这样可以更灵活地进行框架的协议定制，比如请求体和响应体等。这里经过考虑，我们选择了自定义私有协议，这样可以不用去兼容 HTTP 的帧格式，更方便协议的扩展。

### 二、协议需要支持能力

自定义一套私有协议，首先我们需要考虑协议设计上应该需要支持的能力有哪些，如下：

| 能力     | 诉求                                 |
| -------- | ------------------------------------ |
| 高性能   | 协议的设计应该充分考虑传输的性能问题 |
| 可扩展   | 协议应该是可扩展的，支持版本迭代     |
| 超时控制 | 协议支持超时信息透传                 |
| 认证鉴权 | 协议支持认证鉴权信息透传             |
| 流式     | 协议支持流式传输能力                 |
| 数据压缩 | 协议支持数据报文压缩                 |
| tracing  | 协议支持 tracing 信息的透传          |
| 序列化   | 协议支持多种序列化方式               |
| 心跳     | 协议支持心跳请求的发送               |
| .......  | ......                               |



这些能力算是一个优秀的 rpc 协议需要具备的基础能力。想清楚了这一部分，我们就可以开始我们的协议设计了。

### 三、协议格式

一般的协议结构会分为帧头、协议包头、协议包体三个部分，帧头一般都是起到传输控制的作用，协议包头一般是用来传输一些需要在 client 和 server 之间进行透传的一些数据结构，比如序列化的方式、染色 key 等等。协议包体则是 client 发送的请求数据的二进制流或者是 server 返回的响应数据的二进制流。为了减少数据包的大小，一般尽可能节约帧头长度。在实现上面我们所说的协议需要支持的能力的基础上，我们将协议设置成以下形式。

![img](/images/go-rpc/7-1.jpg)

帧头 FrameHeader 的总长度为 15 byte

第一个 1个 byte 为魔数，魔数是什么呢，看到网上有一段解释，觉得非常到位。魔数（magic number）一般是指硬写到代码里的整数常量，数值是编程者自己指定的，其他人不知道数值有什么具体意义，表示不明觉厉，就称作 magic number。这里主要是用来作为我们框架协议的一个唯一标识。

第二个 1 byte 为版本号，我们上面说到了，协议应该是可扩展的，支持版本迭代。所以这里需要 1 byte 的版本号来进行版本迭代。

第三个 1 byte 为消息类型，主要是用来区分普通消息和心跳消息。我们用 0x0 来表示普通消息，用 0x1 来表示心跳消息，客户端向服务端发送心跳包表示自己还是存活的。

第四个 1 byte 表示请求类型，用 0x0 来表示一发一收，0x1 来表示只发不收，0x2 表示客户端流式请求，0x3 表示服务端流式请求，0x4 表示双向流式请求。

第五个 1 byte 表示请求是否压缩，client 和 server 会根据这个标志位决定对传输的数据是否进行压缩/解压处理。0x0 默认不压缩，0x1 压缩

第六个 2 byte 表示流 id ，这里是为了支持后续流式传输的能力，用 2 个字节进行表示。

第七个 4 byte 表示消息的长度，用 4 个字节进行表示。

第八个 4 byte 是保留位，这里留了 4个字节的保留位，方便后续协议进行扩展

### 四、协议的实现

帧头的实现非常简单，只需要定义一个 go 的结构体就可以进行实现了，如下：

```go
type FrameHeader struct {
   Magic uint8    // magic
   Version uint8  // version
   MsgType uint8  // msg type e.g. :   0x0: general req,  0x1: heartbeat
   ReqType uint8  // request type e.g. :   0x0: send and receive,   0x1: send but not receive,  0x2: client stream request, 0x3: server stream request, 0x4: bidirectional streaming request
   CompressType uint8 // compression or not :  0x0: not compression,  0x1: compression
   StreamID uint16    // stream ID
   Length uint32      // total packet length
   Reserved uint32  // 4 bytes reserved
}
```

用了一个 FrameHeader 结构体定义帧头，只需要在打解包的时候，把帧头里面的属性按照顺序写入二进制流里面即可。

对于包头和包体的实现，我们有两种思路。

第一种是包头用一个数据结构表示，包体则是用一个 []byte 数组表示二进制流，这样在进行打解包的时候，只需要先将包头序列化成二进制，然后与二进制的包体数据进行拼接得到包头+包体数据，再前面拼接上二进制的帧头数据，即帧头+包头+包体，这就是一个完整的二进制帧。用 proto 文件定义如下：

```go
// 包头
message RequestHeader {
    string  service_path = 1;          // 请求服务路径
    map<string, bytes> metadata = 2;  // 透传的数据
    ...
}
// 包体
message RequestBody {
  	bytes payload = 1 ;   // 请求体
}                
```

第二种则是包头和包体都放在同一个数据结构里面，包头里面的字段和表示包体的字段都是这个结构的属性。用 proto 文件定义如下：

```go
// 包头+包体
message Request {
    string  service_path = 2;          // 请求服务路径
    map<string, bytes> metadata = 3;  // 透传的数据
    bytes  payload = 4;               // 请求体
}
```

这里我们选择第二种方式实现，原因是压缩和序列化比较方便。

实际上，由于请求和响应的包头里面所带的数据可能不一致，包头还可以分为请求头和响应头。框架中的请求头和响应头用 proto 定义如下：

```go
message Request {
    string  service_path = 2;          // 请求服务路径
    map<string, bytes> metadata = 3;  // 透传的数据
    bytes  payload = 4;               // 请求体
}

message Response {
    uint32 ret_code = 1;               // 返回码 0-正常 非0-错误
    string ret_msg = 2;                 // 返回消息，OK-正常，错误会提示详情
    map<string, bytes> metadata = 3;   // 透传的数据
    bytes payload = 4;                 // 返回体
}
```

可以看到，client 发起请求时，请求头可能需要带上请求的服务路径 servicePath， servicePath 的格式是 /serviceName/method ，所以通过解析 servicePath 我们就可以获取服务名和方法名，server 需要根据服务名找到相应的 service 进行处理，需要根据方法名找到 service 相应的 handler 处理请求。 metadata 则是一个 k/v map，主要是透传一些 key/value 参数，比如染色 key 等。payload 是二进制请求体数据

server 返回响应时，主要包括一个是否正常的状态码 ret_code，以及返回的消息 ret_msg，同样会带一个 k/v map 结构的 metadata 进行参数透传。payload 是二进制响应体数据。

### 小结

本章主要是从实现的角度介绍了如何进行协议选型、如何设计一款自定义私有协议。下一章会基于协议介绍数据的打解包实现。