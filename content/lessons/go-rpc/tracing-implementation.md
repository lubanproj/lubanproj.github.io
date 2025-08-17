---
title: "第十九章：分布式链路追踪实现 —— jaeger"
date: 2020-02-19T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-19"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/tracing-implementation/"
---

上一章我们介绍了分布式链路追踪的原理、opentracing 规范并对 jaeger 进行了简单介绍，这一章我们将介绍使用 jaeger 来进行分布式链路追踪的具体实现。

### 一、运行效果

由于很多同学没有接触过分布式链路追踪，所以我们这一次改变方式，先给大家看一下我们需要实现的效果，然后一一讲解怎么去实现。

代码有一个 examples 目录，里面放了一些简单的 demo。jaeger 就放了使用 jaeger 实现链路追踪的 demo，注意，在运行 demo 之前，我们需要先运行 jaeger（具体怎么运行可以参考上章，jaeger run 起来后默认在 localhost:16686 监听），我们先运行起来看看效果，如下：

```shell
cd examples/jaeger
go run server.go
### 另起终端
go run client.go
```

在 Jaeger UI 的最左边可以看到有 gorpc-client-jaeger、gorpc-server-jaeger 两个 Service，点击右边的 Trace 可以看到具体的调用链，我们不妨拿 client 举例，如下：

![img](/images/go-rpc/19-1.jpg)

点击 /helloworld.Greeter/SayHello 可以看到 client 的具体的调用链，如下：

![img](/images/go-rpc/19-2.jpg)

### 二、实现思路

上面的调用链路其实非常简单，要展示出上图，只需要分别为 client 和 server 上报一个 span 即可。那么我们如何为 client 和 server 上报 span 呢？这其实就是我们的核心问题。

我们知道，分布式链路追踪其实是类似 ”埋点“，既然是 ”埋点“，我们希望对框架代码来说，尽量做到 “无侵入”。要做到这一点，我们考虑上报使用拦截器实现，同时，将 jaeger 和框架解耦，用插件化的思想，将 jaeger 初始化这一步统一放到插件初始化里面去做。

### 三、插件化实现

上面说到了，jaeger 的初始化过程是使用插件化实现的。

tracing 类插件的初始化过程比较特殊，需要返回一个 Tracer，所以这里单独定义一类 TracingPlugin 用来实现 tracing 插件的初始化。

```go
// TracingPlugin defines the standard for all tracing plug-ins
type TracingPlugin interface {
   Init(...Option) (opentracing.Tracer, error)
}
```

这里我们定义一个结构 Jaeger 来实现 TracingPlugin 接口

```go
// Jaeger implements the opentracing specification
type Jaeger struct {
   opts *plugin.Options
}
```

实现 Init(...Option) (opentracing.Tracer, error) 接口，如下：

```go
func (j *Jaeger) Init(opts ...plugin.Option) (opentracing.Tracer, error) {

	for _, o := range opts {
		o(j.opts)
	}

	if j.opts.TracingSvrAddr == "" {
		return nil, errors.New("jaeger init error, traingSvrAddr is empty")
	}

	return initJaeger(j.opts.TracingSvrAddr, JaegerServerName, opts ...)

}

func initJaeger(tracingSvrAddr string, jaegerServiceName string, opts ... plugin.Option) (opentracing.Tracer, error) {
   cfg := &config.Configuration{
      Sampler : &config.SamplerConfig{
         Type : "const",  // Fixed sampling
         Param : 1,       // 1= full sampling, 0= no sampling
      },
      Reporter : &config.ReporterConfig{
         LogSpans: true,
         LocalAgentHostPort: tracingSvrAddr,
      },
      ServiceName : jaegerServiceName,
   }

   tracer, _, err := cfg.NewTracer()
   if err != nil {
      return nil, err
   }

   opentracing.SetGlobalTracer(tracer)

   return tracer, err
}
```

上面一段代码核心其实主要做了两件事，第一是初始化 jaeger 的配置，并且通过这些初始化配置来创建一个 tracer 实例，第二是将这个 tracer 实例作为 opentracing 规范的实现。之前我们说到了 opentracing 只是一套规范，并没有进行链路追踪的具体实现，所以无论你是使用 jaeger 还是 zipkin 等其他链路追踪系统，你都需要进行 opentracing.SetGlobalTracer(tracer) ，将 tracer 设为 opentracing 的真正实现。

### 四、 jaeger 初始化

因为 client 和 server 都要生成 span 并且进行上报，所以 client 和 server 都需要对 jaeger 进行初始化。

#### server 初始化

server 侧 jaeger 的初始化过程，也是在插件初始化的步骤中完成的，之前我们说了插件初始化过程的 consul 初始化，server 的 Serve 方法中，在所有的服务 service 进行初始化之前，会去进行插件的初始化，如下：

```go
func (s *Server) Serve() {

   err := s.InitPlugins()
   if err != nil {
      panic(err)
   }

   ...
   for _, service := range s.services {
      go service.Serve(s.opts)
   }  
}
```

InitPlugins 这个方法完成了所有的插件初始化操作，consul 和 jaeger 的初始化都是在这个方法中完成的。这里我们只专注于 jaeger 的初始化，如下：

```go
func (s *Server) InitPlugins() error {
   // init plugins
   for _, p := range s.plugins {

      switch val := p.(type) {

      case plugin.ResolverPlugin :
        ...

      case plugin.TracingPlugin :

         pluginOpts := []plugin.Option {
            plugin.WithTracingSvrAddr(s.opts.tracingSvrAddr),
         }

         tracer, err := val.Init(pluginOpts ...)
         if err != nil {
            log.Errorf("tracing init error, %v", err)
            return err
         }

         s.opts.interceptors = append(s.opts.interceptors, jaeger.OpenTracingServerInterceptor(tracer, s.opts.tracingSpanName))

      default :

      }

   }

   return nil
}
```

上面这段代码在插件初始化过程中，假如发现是 tracing 类插件，则会调用插件的 Init 方法去初始化，然后使用 jaeger.OpenTracingServerInterceptor 将 tracer 封装为拦截器，并添加到 server 的拦截器列表中。

#### client 初始化

client 的初始化，是在往下游发起调用之前实现的，如下：

```go
func main() {

	tracer, err := jaeger.Init("localhost:6831")
	if err != nil {
		panic(err)
	}

	opts := []client.Option {
		client.WithTarget("127.0.0.1:8000"),
		client.WithNetwork("tcp"),
		client.WithTimeout(2000 * time.Millisecond),
		client.WithInterceptor(jaeger.OpenTracingClientInterceptor(tracer, "/helloworld.Greeter/SayHello")),
	}
	c := client.DefaultClient
	req := &helloworld.HelloRequest{
		Msg: "hello",
	}
	rsp := &helloworld.HelloReply{}

	for i:= 1; i< 200; i ++ {
		err = c.Call(context.Background(), "/helloworld.Greeter/SayHello", req, rsp, opts ...)
		fmt.Println(rsp.Msg, err)
		time.Sleep(100 * time.Millisecond)
	}

}
```

上面一大段代码主要是有关键的两步操作，第一，进行 jaeger 初始化 ，如下：

```go
tracer, err := jaeger.Init("localhost:6831")
```

第二，在 client 的 Option 中，使用 jaeger.OpenTracingClientInterceptor 将 tracer 封装为一个拦截器，并且添加到 client 的拦截器列表中。

### 五、拦截器方式实现 jaeger 的 span 生成

上面我们说到了，为了减少对框架代码的侵入性，我们采用拦截器的方式实现 span 的生成。

#### server 拦截器

server 端上报 span，主要的步骤是，先调用 tracer.Extract 解析 Span 的上下文信息，获得一个 SpanContext，接着调用 tracer.StartSpan 进行创建一个 server span，并且把 server span 放到上下文 context 中进行透传，jeager 会自动对 span 进行上报。代码如下：

```go
// OpenTracingServerInterceptor packaging jaeger tracer as a server interceptor
func OpenTracingServerInterceptor(tracer opentracing.Tracer, spanName string) interceptor.ServerInterceptor {

   return func(ctx context.Context, req interface{}, handler interceptor.Handler) (interface{}, error) {

      mdCarrier := &jaegerCarrier{}

      spanContext, err := tracer.Extract(opentracing.HTTPHeaders, mdCarrier)
      if err != nil && err != opentracing.ErrSpanContextNotFound {
         return nil, errors.New(fmt.Sprintf("tracer extract error : %v", err))
      }
      serverSpan := tracer.StartSpan(spanName, ext.RPCServerOption(spanContext),ext.SpanKindRPCServer)
      defer serverSpan.Finish()

      ctx = opentracing.ContextWithSpan(ctx, serverSpan)

      serverSpan.LogFields(log.String("spanName", spanName))

      return handler(ctx, req)
   }

}
```

#### client 拦截器

client 端上报 span，主要的步骤是，先通过 opentracing.SpanFromContext 获取上游带下来的 span 上下文信息，接着调用 tracer.StartSpan 创建一个 client span，通过调用 tracer.Inject，将所需要透传给下游的一些信息塞到 Span 里面。jaegerCarrier 是一种 map[string] []byte 结构，用来作为传输一些 key-value 数据的载体。具体代码实现如下：

```go
type jaegerCarrier map[string][]byte

// OpenTracingClientInterceptor packaging jaeger tracer as a client interceptor
func OpenTracingClientInterceptor(tracer opentracing.Tracer, spanName string) interceptor.ClientInterceptor {

   return func (ctx context.Context, req, rsp interface{}, ivk interceptor.Invoker) error {

      var parentCtx opentracing.SpanContext
  
      if parent := opentracing.SpanFromContext(ctx); parent != nil {
        parentCtx = parent.Context()
      }

      clientSpan := tracer.StartSpan(spanName, ext.SpanKindRPCClient, opentracing.ChildOf(parentCtx))
      defer clientSpan.Finish()

      mdCarrier := &jaegerCarrier{}

      if err := tracer.Inject(clientSpan.Context(), opentracing.HTTPHeaders, mdCarrier); err != nil {
         clientSpan.LogFields(log.String("event", "Tracer.Inject() failed"), log.Error(err))
      }

      clientSpan.LogFields(log.String("spanName", spanName))

      return ivk(ctx, req, rsp)

   }
}
```