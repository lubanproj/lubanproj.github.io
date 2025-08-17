---
title: "第十四章：插件体系实现"
date: 2020-02-14T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-14"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/plugin/"
---

### 一、什么是插件？

插件（plug-in），是一个程序的辅助或者扩展功能模块，对程序来说可有可无，但它能给程序提供一种额外的功能。

插件化思想在不同的场景有不同的运用。对于前台应用来说，插件化主要解决减少应用程序大小、免安装扩展功能。对于后台应用来说，插件化主要是用来减少模块间的依赖，降低模块间耦合度。

### 二、框架插件化设计

整个框架的插件化设计如下：

![img](/images/go-rpc/14-1.jpg)

框架的 plugin 模块用来管理所有的插件。所有的第三方插件都需要实现 plugin 的标准接口。包括插件的注册、配置初始化等。server 模块在启动时会去遍历所有插件，读取它们的配置并进行初始化。这样设计的好处是，所有的插件都是可插拔的，同时也降低了与框架的耦合度。server 不需要知道有哪些插件，每个插件做了什么事情，跟 plugin 模块唯一的交互就是遍历所有插件，初始化配置而已。

### 三、插件化具体实现

#### 1、定义插件接口

定义 Plugin 接口，作为所有插件的统一标准，如下：

```go
// 插件
type Plugin interface {
	Init(...Option) error
}
```

所有的插件都需要加载自己的配置，所以都需要实现 Init 方法来加载配置。

#### 2、开放注册入口给插件调用进行注册

```go
var PluginMap = make(map[string]Plugin)

func Register(name string, plugin Plugin) {
   if PluginMap == nil {
      PluginMap = make(map[string]Plugin)
   }
   PluginMap[name] = plugin
}
```

#### 3、server 加载插件配置

（1）在 Server 中添加 plugins 成员变量，它是一个插件数组。

```go
// gorpc Server, a Server can have one or more Services
type Server struct {
   opts *ServerOptions
   services map[string]Service
   plugins []plugin.Plugin
}
```

（2）当调用 server.New 函数时，遍历插件 PluginMap，将所有插件 Plugin 添加到 plugins 中去。

```go
func NewServer(opt ...ServerOption) *Server{

   s := &Server {
      opts : &ServerOptions{},
      services: make(map[string]Service),
   }

   for _, o := range opt {
      o(s.opts)
   }

   for pluginName, plugin := range plugin.PluginMap {
      if !containPlugin(pluginName, s.opts.pluginNames) {
         continue
      }
      s.plugins = append(s.plugins, plugin)
   }

   return s
}
```

（3）在调用 Server.Serve() 方法时，在 server 中的所有 service 提供服务之前，调用 InitPlugins 方法进行插件的配置初始化。

```go
func (s *Server) Serve() {

   err := s.InitPlugins()
   if err != nil {
      panic(err)
   }

   for _, service := range s.services {
      go service.Serve(s.opts)
   }

   ch := make(chan os.Signal, 1)
   signal.Notify(ch, syscall.SIGTERM, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGSEGV)
   <-ch

   s.Close()
}
```

我们来看看 InitPlugins 这个方法的具体实现：

```go
func (s *Server) InitPlugins() error {
   // init plugins
   for _, p := range s.plugins {
      p.Init()
   }

   return nil
}
```

它的主要功能是遍历所有的插件，并进行配置初始化。这里在后面具体实现服务发现、负载均衡等插件时，配置初始化的地方有变动，这里后面再进行讲解。

### 四、如何开发一款插件

基于上面的插件体系，开发一款插件非常简单，只需要两步即可。下面以服务发现的插件 consul 进行举例。

#### 1、插件注册

```go
const Name = "consul"

func init() {
   plugin.Register(Name, ConsulSvr)
   ...
}

var ConsulSvr = &Consul {
	opts : &plugin.Options{},
}
```

调用 plugin.Register 函数进行插件注册。注册一个实现了 Plugin 接口的一个插件 Consul。init 函数会在框架初始化前执行，将名字为 consul 的插件注册到插件 Map（PluginMap）里面。

#### 2、实现 Plugin 接口

这里需要实现 Plugin 的 Init 函数，在 Init 函数里面进行插件初始化。这里具体做了些什么事情我们再介绍 consul 实现时再进行讲解。

```go
func (c *Consul) Init(opts ...plugin.Option) error {
	...
  // 一些 consul 初始化逻辑
}
```

经过上面两步，我们实现了一个名字为 consul 的插件。server 在初始化时会遍历 PluginMap，拿到注册的插件 list。然后调用插件自身的 Init 方法进行插件初始化。这样就实现了将插件 ”插入“ 到框架中运行。实现了可插拔。

### 小结

本章主要介绍了插件体系的实现。包括插件化思想、插件化设计和框架具体的插件化实现。