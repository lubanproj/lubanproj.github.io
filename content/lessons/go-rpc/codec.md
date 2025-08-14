---
title: "第八章：协议编解码实现"
date: 2020-02-08T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-8"
layout: "single"
---

上一章我们介绍了协议的格式、协议的设计和实现。这一章主要重点说说框架的协议编解码。

### 一、什么是编解码？

上一章说到了，client 向 server 发送数据包，把请求包转成二进制数据流后，不是直接发送，而是按照协议的格式，拼装成一个数据帧之后，将二进制的数据帧发送给 server。server 读取到这个数据帧后，解析出 request，然后处理请求，得到 response，将 response 拼装帧头、包头等信息，得到一个完整的数据帧，然后返回给 client。client 拿到数据帧之后，从 server 返回的数据帧解析出 response，这就是一次 rpc 完整的数据流转过程。

在这个过程中，将业务数据包装成指定协议格式的数据包就是编码的过程。从指定协议格式中的数据包中取出业务数据的过程就是解码的过程。

### 二、解码实现

上一章我们说了协议格式如下：

![img](/images/go-rpc/7-1.jpg)

#### 1、思路

解码需要从这一个数据帧中解析出 request/response，即二进制的包体数据。那么我们首先需要读出帧头。

帧头是固定长度是 15 byte ，所以只需要读取一个数据帧的前 15 byte 就行。上一章我们说到了，我们是把包头+包体放在一个数据结构 Request/Response 里面进行 protobuf 序列化的。如下：

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

在帧头里面，我们在第 7-11 byte 定义了消息长度。只需要读出帧头里面定义的消息长度，则可以得到包头+包体的总长度，然后进行 protobuf 反序列化，就可以得到 Request/Response 对象，然后就可以通过 Request/Response 对象里面的 payload 字段即可获取到我们的二进制请求体/响应体。

#### 2、读取数据帧

下面我们来看看代码实现。按照惯例，我们还是先用一个 Codec 接口来定义编解码的通用标准，实现可插拔，并且方便业务自定义。defaultCodec 是 Codec 接口的默认实现。编码 Encode 是将一个被序列化过后的 Request/Response 对象，拼装帧头成为一个完整的数据帧。解码 Decode 则是从一个完整的数据帧中解出具体的 request/response。

```go
type Codec interface {
   Encode([]byte) ([]byte, error)
   Decode([]byte) ([]byte, error)
}
type defaultCodec struct{}
```

从上面的分析，我们可知解码最重要的部分其实就是解析出数据帧。这里我们定义一个专门的结构来进行数据帧的读取，如下：

```go
type Framer interface {
   // read a full frame
   ReadFrame(net.Conn) ([]byte, error)
}

type framer struct {
   buffer []byte
   counter int  // to prevent the dead loop
}
```

Framer 这个接口就是读取数据帧的通用化定义。framer 是 Framer 的一个默认实现，buffer 是用一块默认的固定内存 1024 byte，来避免每次读取数据帧都需要创建和销毁内存的开销。当内存不够时，会扩容成原来的两倍，如下：

```go
func NewFramer() Framer {
   return &framer {
      buffer : make([]byte, DefaultPayloadLength),
   }
}

func (f *framer) Resize() {
   f.buffer = make([]byte, len(f.buffer) * 2)
}
```

为了避免包过大时或者其他不可知意外造成死循环，这里加了一个 counter 计数器。当 buffer > 4M 时或者 扩容的次数 counter 大于 12 时，会跳出循环，不再 Resize ，如下：

```go
for uint32(len(f.buffer)) < length && f.counter <= 12 {
   f.buffer = make([]byte, len(f.buffer) * 2)
   f.counter++
}
```

读取帧头 FrameHeader 的完整实现如下：

```go
func (f *framer) ReadFrame(conn net.Conn) ([]byte, error) {

   frameHeader := make([]byte, codec.FrameHeadLen)
   if num, err := io.ReadFull(conn, frameHeader); num != codec.FrameHeadLen || err != nil {
      return nil, err
   }

   // validate magic
   if magic := uint8(frameHeader[0]); magic != codec.Magic {
      return nil, codes.NewFrameworkError(codes.ClientMsgErrorCode, "invalid magic...")
   }

   length := binary.BigEndian.Uint32(frameHeader[7:11])

   if length > MaxPayloadLength {
      return nil, codes.NewFrameworkError(codes.ClientMsgErrorCode, "payload too large...")
   }

   for uint32(len(f.buffer)) < length && f.counter <= 12 {
      f.buffer = make([]byte, len(f.buffer) * 2)
      f.counter++
   }

   if num, err := io.ReadFull(conn, f.buffer[:length]); uint32(num) != length || err != nil {
      return nil, err
   }

   return append(frameHeader, f.buffer[:length] ...), nil
}
```

这里是先读取出 15 byte 的帧头，然后从帧头中获取包头+包体总长度 length，然后读取出包头+包体。

核心其实就是两个方法：

1、io.ReadFull 用来读取指定数据长度的二进制包，这里用来实现刚好读取 15 byte 的帧头和指定 length 的包头+包体数据。

2、binary.BigEndian 使用 binary 这个包按照大端序的方式从二进制数据流中读取数据。这里稍微解释下大端序和小端序，它们是字节存储的两种顺序方式

- 大端序：高位字节存入低地址，低位字节存入高地址
- 小端序：低位字节存入低地址，高位字节存入高地址

在计算机内部，小端序被广泛应用于现代性 CPU 内部存储数据；而在其他场景譬如网络传输和文件存储使用大端序。我们这里采用的是大端序。

#### 3、解码

读取出数据帧后，我们去掉帧头，就是包头+包体，如下：

```go
func (c *defaultCodec) Decode(frame []byte) ([]byte,error) {
   return frame[FrameHeadLen:], nil
}
```

### 三、编码实现

编码的实现，其实就是将一个经过序列化的 request/response 二进制数据，拼接帧头形成一个完整的数据帧。

```go
func (c *defaultCodec) Encode(data []byte) ([]byte, error) {

   totalLen := FrameHeadLen + len(data)
   buffer := bytes.NewBuffer(make([]byte, 0, totalLen))

   frame := FrameHeader{
      Magic : Magic,
      Version : Version,
      MsgType : 0x0,
      ReqType : 0x0,
      CompressType: 0x0,
      Length: uint32(len(data)),
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.Magic); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.Version); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.MsgType); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.ReqType); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.CompressType); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.StreamID); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.Length); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, frame.Reserved); err != nil {
      return nil, err
   }

   if err := binary.Write(buffer, binary.BigEndian, data); err != nil {
      return nil, err
   }

   return buffer.Bytes(), nil
}
```

可以看到，是先写帧头数据，然后写包头+包体数据（data），这里主要是用了一个 binary.Write 方法，按照大端序进行二进制数据的写操作。

### 小结

本章主要介绍了协议编解码的实现，介绍了整个编码和解码的过程。