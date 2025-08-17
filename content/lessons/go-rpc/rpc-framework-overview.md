---
title: "第二章：RPC 框架概览"
date: 2020-02-02T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-2"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/rpc-framework-overview/"
---

### 一、模块

上一章我们说到了要想设计出一款优秀的 RPC 框架，需要解决的问题，包括开发效率、通信效率、数据传输、通用化能力、服务治理等。为了解决这些问题，框架首先要支持一些基本的能力，在我们的框架中，这些能力支持如下：

- client 模块：支持客户端发包
- server 模块：支持服务端收包
- transport 模块：提供底层的通信能力
- codec 模块：自定义协议的解析、序列化和反序列化
- pool 模块：池技术，支持连接池、对象池等实现，提供客户端连接的复用、对象复用等能力
- log 模块：提供日志能力
- selector 模块：提供寻址能力，支持服务发现（resolver）、负载均衡 （loadbalance）等默认实现
- stream 模块：提供客户端和服务端上下文数据透传能力，后续还会支持流式传输
- protocol 模块：提供自定义私有协议能力
- plugin 模块：提供第三方插件化支持能力
- interceptor 模块：提供框架拦截器能力
- metadata 模块：提供客户端和服务端参数传递能力

### 二、整体架构

整体架构如下图：

![img](/images/go-rpc/2-1.jpg)

主要可以分为三层：

#### 1、业务层：

最上层是业务层，业务层主要包括 client 和 server ，server 层发布一个服务，client 层根据业务需要，拼装请求参数，发起 invoke 调用，往 server 端进行发包。server 端收到包之后，解析请求参数，调用相应业务函数进行处理，回写响应。这里 client 为了提高通信效率，会使用连接池进行连接复用。

#### 2、组件层：

组件层主要包括 interceptor （拦截器组件）、resolver（服务发现组件）、loadbalance（负载均衡组件）、codec（打解包组件）、protocol（协议组件）、log（日志组件）、metadata（支持上下文参数透传）。

组件层主要是提供了一种给 client 和 server 进行调用的通用化能力，在 rpc 框架中，所有的组件应该是自定义、可插拔的。

#### 3、传输层：

传输层即 transport，它的核心任务是通信。transport 完成了对客户端和服务器之间如何建立连接、如何发送数据、如何为请求分配连接、连接状态的管理以及连接何时关闭等问题的处理，传输层的底层是基于 tcp 、udp 等底层传输层协议进行实现。

#### 4、插件层：

插件层即 plugin，它主要是对接第三方业务系统。包括一些微服务治理的第三方服务，比如 consul —— 提供服务发现的服务和 jaeger —— 提供分布式链路追踪服务的服务。框架层面实现了基于 consul 进行服务发现的插件和基于 jaeger 进行分布式链路追踪的插件。

### 三、技术选型

#### 1、协议

协议是客户端和服务端之间对话的 "语言" ，是客户端和服务端双方必须共同遵从的一组约定。如怎么样建立连接、怎么样互相识别等。关于 client 和 server 之间进行传输的协议选型，这里有两种方案，第一种是直接使用业内比较成熟的协议，比如 http 协议。但是 http 是文本型协议，传输效率太低，所以可以考虑 http2 协议，http2 协议是二进制协议，传输效率远远超过 http1.x，例如 grpc 就是基于 http2 协议去做的协议定制，将 grpc 的一些协议信息封装在 http2 的帧信息里面进行传递。详细可参考：[grpc 协议](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-HTTP2.md)

第二种是自定义一套二进制私有协议。这套私有协议专门为了这款 RPC 框架的 client 和 server 进行通信而生，这样可以更灵活地进行框架的协议定制，比如请求体和响应体等。这里经过考虑，我选择了自定义私有协议，这样可以不用去兼容 HTTP 的帧格式，更方便协议的扩展。

#### 2、开发语言

关于开发语言的选择，后台比较常用的开发语言一般有 java、c++、go、python、nodejs 等，结合语言的并发支持、周边生态、语法糖、易用性等因素综合考虑，最终还是选择了 go，原因是因为 go 是一门新生的语言，在语言的语法糖上没有历史包袱，设计得非常简单易用，而且 go 的协程机制对高并发有着天然的支持。

#### 3、序列化方式

业内比较常见的序列化方式有 json、protobuf、gogoprotobuf、xml、thrift、flatbuffer、msgpack 等，对这几种组件进行了性能测试结果为 : gogoprotobuf > msgpack > flatbuffers > thrift > protobuf > json > xml 。因为 RPC 框架支持代码生成和反射两种调用方式，反射调用选择了能支持反射且性能又高的 msgpack，代码生成选择了使用比较广泛、性能还不错的 protobuf。

#### 4、服务发现

go 周边生态里面提供服务发现能力的开源组件主要有 consul 和 etcd 等，这两款组件都被广泛使用，都是基于 raft 分布式一致性协议，提供了 k/v 存储的能力。考虑到应用层面，etcd 的 api 比较简单，主要是针对 kv 的一些 CRUD 操作。这里 consul 提供的能力比较全面一点，封装了服务发现、健康检查，内置了 DNS server 等。考虑到这一点，我们选了 consul 作为框架服务发现的默认实现。

#### 5、分布式链路追踪

业界针对分布式链路追踪，有一个统一的标准，即 opentracing ，opentracing 约定了分布式链路追踪的组件进行 span 上报的标准格式。它为每种语言都提供了 api 支持，go 语言标准可以参考 [opentracing-go](https://github.com/opentracing/opentracing-go) ，业内实现了这个标准的组件主要有 zipkin 和 jaeger。zipkin 是用 java 实现的，提供了 go 的客户端版本。jaeger 则是纯 go 实现的。所以这里选择了 jaeger 进行分布式链路追踪的实现

### 小结

这一章主要进行了 RPC 框架设计的一个总览介绍，包括模块、架构、技术选型。这里决定了后续开发的方向，牵涉到后面代码的具体实现。下一章我们将开始以代码的方式，一步一步去实现一款高性能的 rpc 框架。