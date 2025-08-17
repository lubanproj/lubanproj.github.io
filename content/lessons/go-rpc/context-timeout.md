---
title: "第六章：超时机制"
date: 2020-02-06T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-6"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/context-timeout/"
---

### 一、超时

超时是 rpc 请求中最常见的问题之一。一般发生超时的情况都是在涉及到跨系统调用的场景，假如具体划分，可以分为客户端调用超时和服务端超时。

- 假如对客户端超时进行处理，那么当客户端发起请求后，如果在规定时间内没有收到服务端的响应，则直接返回给上游调用超时异常，此时服务端的代码可能仍在运行。
- 假如对服务端超时进行处理，那么当客户端发起一次请求后，会一直等待服务端响应，服务端在方法执行之后的指定时间内如果未执行完程序，则不会继续处理，而是直接返回一个超时异常给到客户端。

我们发现，假如只对客户端进行超时处理，可能会出现一次 rpc 请求 client 返回异常了，server 还在运行，这是一种资源浪费。假如只对服务端进行超时处理，则 client 会循环等待收包，假如 server 的回包丢包了，会造成 client 死循环，这也是不合理的。

那么我们的思路清楚了，最好的超时机制的实现应该是 client 和 server 同时处理超时。

### 二、超时机制的设计

假如有一次请求，请求流程如下所示，A 同时调用了 B、C、D，C 同时调用了 E、F，E 调用了 G。

![img](/images/go-rpc/6-1.jpg)

假如整个请求的超时时间是 2s，那么我们就拿最长的一条链路 A ——> C ——> E ——> G 来说，A 给下游链路的处理时间是 2s，假如 C 处理耗费了 1s，那么 C 给下游 E 的处理时间为 1s，假如 E 处理耗费了 0.5s ，那么留给下游 G 的处理时间就是 0.5s， 假如这条链路中出现下面任何一种情况，则这次请求视为超时：

- C 的处理时间超过了 2s
- E 的处理时间超过了 1s
- G 的处理时间超过了 0.5s

基于对上面请求流程的分析，我们就可以设计出我们的超时机制了，具体如下：

![img](/images/go-rpc/6-2.jpg)

客户端 client 一般是一条请求链路的源头。client 向下游发起调用，如果在规定时间内没有收到服务端的响应，则直接返回超时异常。

对于一次请求的服务端 C 而言，请求从上游到 C 有一个上游传递下来的剩余处理时间。服务端 C 有一个自己处理请求的耗时，处理完之后，往下游发起调用时会有一个带给下游的剩余处理时间。这样，超时的信息就完成了上下游传递。也就是下面的等式：

上游传递下来的剩余处理时间 - 服务端处理请求的时间 = 传递给下游的剩余处理时间

### 三、超时机制的实现

上面我们详细讲解了超时机制的设计，那么我们要如何去实现这样一套超时机制呢？

这里就介绍一下 go 里面一个非常强大的包 —— context

#### 1、什么是 context

Context 是一个非常抽象的概念，中文翻译为 ”上下文“，为了方便理解，我们可以把它看做是 goroutine 的上下文。包括 goroutine 的运行状态、环境等信息。Context 可以用来在 goroutine 之间传递上下文信息，包括：信号、超时时间、k-v 键值对等。同时它可以用作并发控制。它的接口定义如下：

```go
type Context interface {
   // 返回代表 Context 完成的时间
   Deadline() (deadline time.Time, ok bool)
   // 当 Context 被取消或者死亡后，返回一个 channel
   Done() <-chan struct{}
   // 当 Context 被取消或者死亡后，返回错误信息
   Err() error
   // 获取 key 对应的 value
   Value(key interface{}) interface{}
}
```

它主要有上面四个方法，通过 Deadline() 我们可以获取 Context 存活的时间。

#### 2、Context 的父子模型

![img](/images/go-rpc/6-3.jpg)


要理解 Context ，必须要介绍下 Context 的父子模型。假如上图是在某个服务端 server 内进行请求处理的流程。 goroutine A 这里的 Context A 是 goroutine B、C、D 的 parent Context。goroutine E、F 与 goroutine C 共用 context C，Context C 是 Context G 的 parent Context。

Context 的父子模型通俗点说就是，假如父 Context 已经执行完或者超时取消了，那么子 Context 相应地也会被取消。也就是说，上图假如 Context A 被取消了，那么 B、C、D 都会被取消，假如 Context C 被取消了，那么 Context G也会被取消。

#### 3、使用 context 包实现超时控制

使用 context 包实现超时控制，主要用到了下面两个函数：

- context.WithTimeout ：为 Context 设置超时时间，超过这个时间，Context 会被取消执行。
- context.Deadline：返回 Context 完成的时间点。

具体实现：

**（1）client 端：**

- client 发起调用时，通过 client.WithTimeout 方法设置 client Options 参数选项的 timeout 参数的值。

- 判断 client Options 参数选项的 timeout 值是否被设置，假如被设置，则通过 context.WithTimeout 方法设置 parent Context 的超时时间。

  ```go
  if c.opts.timeout > 0 {
     var cancel context.CancelFunc
     ctx, cancel = context.WithTimeout(ctx, c.opts.timeout)
     defer cancel()
  }
  ```

- 对下游链路发起调用，基于 parent Context 去生成子 Context 发起调用。

**（2）server 端：**

- server 端启动时，通过 server.WithTimeout 方法设置 service Options 参数选项的 timeout 参数的值。

- service 在调用 Handle 方法处理请求时，判断 timeout 值是否被设置，假如被设置，则新起一个携带超时时间 timeout 的子 Context。

  ```go
  if s.opts.timeout != 0 {
     var cancel context.CancelFunc
     ctx, cancel = context.WithTimeout(ctx, s.opts.timeout)
     defer cancel()
  }
  ```

通过这样一套机制，则实现了 client 和 server 双端的超时控制。

### 小结

本章主要介绍了超时机制的原理、设计，并且借助 context 包实现了 client 和 server 的超时控制。