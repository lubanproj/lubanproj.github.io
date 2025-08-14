---
title: "第十二章：拦截器实现"
date: 2020-02-12T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-12"
layout: "single"
---

### 一、什么是拦截器？

拦截器，通俗点说，就是在执行一段代码之前或者之后，去执行另外一段代码。 拦截器在业界知名框架中的运用非常普遍。包括 Spring 、Grpc 等框架中都有拦截器的实现。接下来我们想办法从 0 到 1 自己实现一个拦截器。

### 二、实现思路

假设有一个方法 handler(ctx context.Context) ，我想要给这个方法赋予一个能力：允许在这个方法执行之前能够打印一行日志。那我们应该如何去实现呢？

#### 1、定义结构

于是我们轻而易举得想到了定义一个结构 interceptor 这个结构包含两个参数，一个 context 和 一个 handler

```go
type interceptor func(ctx context.Context, handler func(ctx context.Context) )
```

为了能够更加方便，我们将 handler 单独定义成一种类型：

```go
type interceptor func(ctx context.Context, h handler)

type handler func(ctx context.Context)
```

#### 2、申明赋值

接下来，为了实现我们的目标，对 handler 的每个操作，我们都需要先经过 interceptor 。于是我们申明两个 interceptor 和 handler 的变量并赋值

```go
var h = func(ctx context.Context) {
	fmt.Println("do something ...")
}

var inter1 = func(ctx context.Context, h handler) {
  fmt.Println("interceptor1")
  h(ctx)
}
```

#### 3、编写执行函数

编写一个执行函数，看看效果

```go
func main() {

  var ctx context.Context
  var ceps []interceptor
  var h = func(ctx context.Context) {
  	fmt.Println("do something ...")
  }
  var inter1 = func(ctx context.Context, h handler) {
    fmt.Println("interceptor1")
    h(ctx)
  }
  
  ceps = append(ceps, inter1)
  for _ , cep := range ceps {
  	cep(ctx, h)
  }
  
}
```

输出结果为 ：

```go
interceptor1
do something ...
```

ok，我们已经完成了实现这个方法之前 输出一行内容。

是不是大功告成了呢？ wait ... 我们再来加一个 interceptor 试试，于是我们又加了一个 interceptor

```go
var inter2 = func(ctx context.Context, h handler) {
  fmt.Println("interceptor2")
  h(ctx)
}
```

同样，我们编写一个执行函数

```go
func main() {

  var ctx context.Context
  var ceps []interceptor
  
  var h = func(ctx context.Context) {
  	fmt.Println("do something ...")
  }
  var inter1 = func(ctx context.Context, h handler) {
    fmt.Println("interceptor1")
    h(ctx)
  }
  var inter2 = func(ctx context.Context, h handler) {
    fmt.Println("interceptor2")
    h(ctx)
  }
  ceps = append(ceps, inter1, inter2)
  
  for _ , cep := range ceps {
  	cep(ctx, h)
  }

}
```

执行结果如下：

```go
interceptor1
do something ...
interceptor2
do something ...
```

可以看到，在 handler 之前确实输出了两行内容。但是总感觉哪里不太对？？？ wait ... handler 竟然执行了两次。这可不是我们想要的效果，我们希望无论打印多少行内容，应该保证 handler 只执行一次。

### 三、一种实现拦截器的方式

那我们如何保证 handler 只执行一次呢？这里我们就开始转动脑袋，想啊想，其实拦截器无非就是一种递归的思想，那么如何进行递归呢？下面提供一种方式（这其实也是参考了 grpc 的实现）：

这里我们引入一个函数 invoker ，它的结构如下：

```go
type invoker func(ctx context.Context, interceptors []interceptor2 , h handler) error
```

之前的 interceptor 结构也需要变动下，在原来的基础上再传入 invoker ，如下：

```go
type interceptor2 func(ctx context.Context, h handler, ivk invoker) error
```

接下来这个方法很重要，通过它完成了递归。

```go
func getInvoker(ctx context.Context, interceptors []interceptor2 , cur int, ivk invoker) invoker{
	 if cur == len(interceptors) - 1 {
		return ivk
	}
	 return func(ctx context.Context, interceptors []interceptor2 , h handler) error{
		return 	interceptors[cur+1](ctx, h, getInvoker(ctx,interceptors, cur+1, ivk))
	}
}
```

好了，实现了上面的步骤，那么现在假如我们有一个拦截器数组，那么如何实现链式调用呢？也就是实现下面的效果：

![img](https://p1-jj.byteimg.com/tos-cn-i-t2oaga2asx/gold-user-assets/2020/3/16/170df4a96a0ada5c~tplv-t2oaga2asx-jj-mark:1512:0:0:0:q75.awebp)

这里我们用一个方法来把 interceptor 数组串成这一条链，如下：

```go
func getChainInterceptor(ctx context.Context, interceptors []interceptor2 , ivk invoker) interceptor2 {
		if len(interceptors) == 0 {
			return nil
		}
		if len(interceptors) == 1 {
			return interceptors[0]
		}
		return func(ctx context.Context, h handler, ivk invoker) error {
			return interceptors[0](ctx, h, getInvoker(ctx, interceptors, 0, ivk))
		}
} 
```

这样我们的拦截器就基本实现了，完整测试代码如下：

```go
package main

import (
	"context"
	"fmt"
)

type interceptor2 func(ctx context.Context, h handler, ivk invoker) error

type handler func(ctx context.Context)

type invoker func(ctx context.Context, interceptors []interceptor2 , h handler) error

func main() {

	var ctx context.Context
	var ceps []interceptor2
	var h = func(ctx context.Context) {
		fmt.Println("do something")
	}

	var inter1 = func(ctx context.Context, h handler, ivk invoker) error{
		h(ctx)
		return ivk(ctx,ceps,h)
	}
	var inter2 = func(ctx context.Context, h handler, ivk invoker) error{
		h(ctx)
		return ivk(ctx,ceps,h)
	}

	var inter3 = func(ctx context.Context, h handler, ivk invoker) error{
		h(ctx)
		return 	ivk(ctx,ceps,h)
	}

	ceps = append(ceps, inter1, inter2, inter3)
	var ivk = func(ctx context.Context, interceptors []interceptor2 , h handler) error {
		fmt.Println("invoker start")
		return nil
	}

	cep := getChainInterceptor(ctx, ceps,ivk)
	cep(ctx, h,ivk)

}

func getChainInterceptor(ctx context.Context, interceptors []interceptor2 , ivk invoker) interceptor2 {
	if len(interceptors) == 0 {
		return nil
	}
	if len(interceptors) == 1 {
		return interceptors[0]
	}
	return func(ctx context.Context, h handler, ivk invoker) error {
		return interceptors[0](ctx, h, getInvoker(ctx, interceptors, 0, ivk))
	}

}


func getInvoker(ctx context.Context, interceptors []interceptor2 , cur int, ivk invoker) invoker{
	 if cur == len(interceptors) - 1 {
		return ivk
	}
	 return func(ctx context.Context, interceptors []interceptor2 , h handler) error{
		return 	interceptors[cur+1](ctx, h, getInvoker(ctx,interceptors, cur+1, ivk))
	}
}
```

执行结果为：

```go
do something
do something
do something
invoker start
```

可以看到每次 Invoker 执行前我们都调用了 handler，但是 Invoker 只被调用了一次，完美地实现了我们的诉求，一个简化版的拦截器诞生了。

### 小结

本章从 0 到 1，一步步去实现了一个拦截器。本章提供了一种递归的实现思路，当然读者也可以用其他的思路去实现。