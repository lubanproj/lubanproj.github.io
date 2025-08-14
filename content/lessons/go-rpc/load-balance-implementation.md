---
title: "第十七章：负载均衡实现"
date: 2020-02-17T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-17"
layout: "single"
---

其实我们在前面介绍服务发现的时候就顺带牵涉到了负载均衡。我们在这一章对负载均衡进行一个详细的讲解。

### 一、什么是负载均衡？

负载均衡（load balance），它的职责是将网络请求，或者其他形式的负载 “均摊” 到不同的机器上吗，从而避免出现集群中某些服务器压力过大，而另一些服务器又比较空闲的情况。通过负载均衡，我们可以让每台服务器获取到适合自己处理能力的负载。在为高负载服务器分流的同时，还可以避免资源浪费，一举两得。负载均衡可分为软件负载均衡和硬件负载均衡。在我们日常开发中，一般很难接触到硬件负载均衡。但软件负载均衡还是可以接触到的，比如 nginx。

### 二、常用的负载均衡算法

软件负载均衡一般都是通过负载均衡算法实现，常用的负载均衡算法有随机、轮询、加权轮询、一致性哈希等。

1、随机

请求随机分配到各个服务器。

- 优点：使用简单
- 缺点：不适合机器配置不同的场景

2、轮询

将所有请求依次分发到每台服务器上，适合服务器硬件配置相同的场景。

- 优点：每台服务器的请求数目相同
- 缺点：服务器压力不一样，不适合服务器配置不同的情况

3、加权轮询

根据服务器硬件配置和负载能力，为服务器设置不同的权重，在进行请求分发时，不同权重的服务器分配的流量不同，权重越大的服务器，分配的请求数越多，流量越大。

- 优点：根据权重，调节转发到后端服务器的请求数目
- 缺点：相比于轮询而言，使用相对复杂

4、一致性哈希

按照一致性哈希算法，将请求分发到每台服务器上。

- 优点：能够避免传统哈希算法因服务器数量变化而引起的集群雪崩问题。
- 缺点：实现较为复杂，请求量比较小的场景下，可能会出现某个服务器节点完全空闲的情况

### 三、框架的负载均衡实现

框架目前为止，实现了随机、轮询、加权轮询三种负载均衡算法，一致性哈希算法暂未支持，欢迎大家一起贡献代码。

#### 1、随机

随机算法是框架默认的负载均衡算法。要实现一个随机算法的负载均衡器，首先要实现负载均衡的通用接口 Balancer，如下：

```go
type randomBalancer struct {

}

func (r *randomBalancer) Balance(serviceName string, nodes []*Node) *Node {
	if len(nodes) == 0 {
		return nil
	}
	rand.Seed(time.Now().Unix())
	num := rand.Intn(len(nodes))
	return nodes[num]
}
```

我们先定义一个 randomBalancer 结构，然后实现 Balancer 的 Balance 方法。随机负载均衡器实现非常简单，使用 go 自带的 rand 工具类，用当前时间生成随机种子，根据服务列表的长度去随机生成一个数字，以此为数组下标去取相应的服务节点就好。

#### 2、轮询

轮询算法的实现比随机算法要稍微复杂一点。因为考虑到一个 Server 可能有多个 Service （Service 是提供的具体服务），由于每个服务有其唯一的服务名 serviceName，所以我们需要针对每一个 serviceName 的服务器地址列表，都需要去记录当前访问的下标。

这里，每个服务名和其对应的服务器列表是一个映射关系，所以我们用一个 map 结构来保存所有服务的服务名和其对应的服务器列表。考虑到并发安全性，这里使用 sync.Map，如下：

```go
type roundRobinBalancer struct {
   pickers *sync.Map
   duration time.Duration  // time duration to update again
}
```

由于针对每一个服务 Service，我们还需要记录它的一些状态，比如服务列表的上次访问下标，服务列表的长度，上次访问时间等。所以我们用一个结构来记录这些信息，如下：

```go
type roundRobinPicker struct {
   length int       // service nodes length
   lastUpdateTime time.Time  // last update time
   duration time.Duration    // time duration to update again
   lastIndex int    // last accessed index
}
```

roundRobinPicker 真正实现了根据上次访问下标 lastIndex、服务列表长度 length、上次访问时间 lastUpdateTime 等从一个服务列表里面去获取一个服务节点。如下：

```go
func (rp *roundRobinPicker) pick(nodes []*Node) *Node {
   if len(nodes) == 0 {
      return nil
   }

   // update picker after timeout
   if time.Now().Sub(rp.lastUpdateTime) > rp.duration ||
      len(nodes) != rp.length {
      rp.length = len(nodes)
      rp.lastUpdateTime = time.Now()
      rp.lastIndex = 0
   }

   if rp.lastIndex == len(nodes) - 1 {
      rp.lastIndex = 0
      return nodes[0]
   }

   rp.lastIndex += 1
   return nodes[rp.lastIndex]
}
```

至于 roundRobinBalancer 这个结构，它实现了负载均衡器，也就是实现了 Balancer 的 Balance 方法。

```go
func (r *roundRobinBalancer) Balance(serviceName string, nodes []*Node) *Node {

   var picker *roundRobinPicker

   if p, ok := r.pickers.Load(serviceName); !ok {
      picker = &roundRobinPicker{
         lastUpdateTime: time.Now(),
         duration : r.duration,
         length : len(nodes),
      }
   } else {
      picker = p.(*roundRobinPicker)
   }

   node := picker.pick(nodes)
   r.pickers.Store(serviceName,picker)
   return node
}
```

在 Balance 方法中，会先根据服务的服务名去找到其对应的 roundRobinPicker，然后调用 roundRobinPicker 的 pick 方法去获取访问的服务节点。

#### 3、加权轮询

前面说到了，加权轮询是根据服务器硬件配置和负载能力，为服务器设置不同的权重，在进行请求分发时，不同权重的服务器分配的流量不同，权重越大的服务器，分配的请求数越多，流量越大。假如存在 A、B、C 三台服务器，权重分别是 A : B : C = 4 : 2 : 1，那么普通的加权轮询可能是 {A，A，A，A，B，B，C}，这样的话，会有 5 个联系的请求落在 A 服务器上，这样的调度其实不太好，一段时间内可能有大量的请求落到 A 服务器上，给 A 服务器造成很大压力，当 QPS 很大时容易造成单点故障。

所以我们希望实现一种平滑的加权轮询算法。使得能够出现类似 {A，B，A，C，A，B，A} 这样的效果。

这里参考 nginx 平滑的基于权重轮询算法进行实现。其实很简单，算法主要分为两步：

1、每个节点，用它们当前的值加上自己的权重。

2、选择当前值最大的节点，把它的当前值减去所有节点的权重总和，作为它的新权重

例如`{A:4, B:2, C:1}`三个节点。一开始我们初始化三个节点的当前值为`{0, 0, 0}`。 选择过程如下表：

| 轮数 | 选择前的当前权重 | 选择节点 | 选择后的当前权重 |
| ---- | ---------------- | -------- | ---------------- |
| 1    | {4, 2, 1}        | A        | {-3, 2, 1}       |
| 2    | {1, 4, 2}        | B        | {1, -3, 2}       |
| 3    | {5, -1, 3}       | A        | {-2, -1, 3}      |
| 4    | {2, 1, 4}        | C        | {2, 1, -3}       |
| 5    | {6, 3, -2}       | A        | {-1, 3, -2}      |
| 6    | {3, 5, -1}       | B        | {3, -2, -1}      |
| 7    | {7, 0, 0}        | A        | {0, 0, 0}        |

这样选择出来的服务节点依次是 {A，B，A，C，A，B，A} ，就实现了相对平滑的效果。其实这个算法的本质是保证权重和不变，如上面权重和永远是 7，但是每一次节点被选择之后，当前节点需要减去权重和，所以下一次这一个节点一定不会被选到，避免了某台服务器某段时间流量过于集中的问题，实现了平滑的效果。

框架中加权轮询的实现引入了几个变量：节点权重 weight、节点的当前权重 currentWeight、节点的有效权重 effectiveWeight （某个服务节点挂了后，effectiveWeight 变为 0，防止单点故障）

具体代码实现如下：

```go
type weightedRoundRobinBalancer struct {
   pickers *sync.Map
   duration time.Duration    // time duration to update again
}
```

weightedRoundRobinBalancer 和轮询中 roundRobinPicker 结构类似，这里不作赘述。跟轮询不同的是 wRoundRobinPicker 的结构，它包含了一个 weightedNode 数组，如下：

```go
type wRoundRobinPicker struct {
   nodes []*weightedNode        // service nodes
   lastUpdateTime time.Time  // last update time
   duration time.Duration    // time duration to update again
}
type weightedNode struct {
	node *Node
	weight int
	effectiveWeight int
	currentWeight int
}
```

可以看到，weightedNode 中真正描述了节点权重 weight、节点的当前权重 currentWeight、节点的有效权重 effectiveWeight 这三个变量。

Balance 的过程与轮询类似，如下：

```go
func (w *weightedRoundRobinBalancer) Balance(serviceName string, nodes []*Node) *Node {
   var picker *wRoundRobinPicker

   if p, ok := w.pickers.Load(serviceName); !ok {
      picker = &wRoundRobinPicker{
         lastUpdateTime: time.Now(),
         duration : w.duration,
         nodes : getWeightedNode(nodes),
      }
      w.pickers.Store(serviceName,picker)
   } else {
      picker = p.(*wRoundRobinPicker)
   }

   node := picker.pick(nodes)
   w.pickers.Store(serviceName,picker)
   return node
}
```

可以看到和轮询类似，先通过服务名获取到对应的 wRoundRobinPicker，然后调用 pick 方法进行加权轮询实现。如下：

```go
func (wr *wRoundRobinPicker) pick(nodes []*Node) *Node {
   if len(nodes) == 0 {
      return nil
   }

   // update picker after timeout
   if time.Now().Sub(wr.lastUpdateTime) > wr.duration ||
      len(nodes) != len(wr.nodes){
      wr.nodes = getWeightedNode(nodes)
      wr.lastUpdateTime = time.Now()
   }

   totalWeight := 0
   maxWeight := 0
   index := 0
   for i, node := range wr.nodes {
      totalWeight += node.weight
      if node.weight > maxWeight {
         maxWeight = node.weight
         index = i
      }
   }

   wr.nodes[index].currentWeight -= totalWeight

   return wr.nodes[index].node

}
```

这段代码其实就是实现了加权轮询算法的下面两步。

1、每个节点，用它们当前的值加上自己的权重。

2、选择当前值最大的节点，把它的当前值减去所有节点的权重总和，作为它的新权重

### 小结

本章主要介绍了几种常见的负载均衡算法原理和实现。