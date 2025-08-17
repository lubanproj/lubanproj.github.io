---
title: "第十一章：连接池实现"
date: 2020-02-11T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-11"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/connection-pool/"
---

### 一、为什么需要连接池

连接池是一个创建和管理连接的缓冲池技术。为什么需要连接池呢？我们知道，client 每次向 server 发起请求都会创建一个连接。一般一个 rpc 请求消耗的时间可能是几百毫秒到几秒，也就是说在一个比较短的时间内，这个连接就会被销毁。假设我们一秒钟需要处理 20w 个请求，假如不使用连接池的话，可能几万十几万的连接在短时间内都会被创建和销毁，这对 cpu 资源是一个很大的消耗，同时因为我们的端口数是 1~65535，除了一些端口被计算机内部占用，每次 client 创建连接都需要分配一个端口，假如并发量过大的话，可能会出现计算机端口不够用的情况。

### 二、连接池需要解决的几个问题

上面我们说了为什么需要连接池，为了提高性能和避免端口不够用的情况。那么连接池需要解决那些问题呢？我们先思考下，然后列举如下：

1、连接如何管理

2、连接的创建和销毁过程

3、连接如何进行复用

4、如何判断连接失效，连接何时关闭

5、如何做到并发安全

其实，我们把这些问题解决完之后，发现一个连接池基本就已经被实现了。

### 三、连接池的具体实现

#### 1、连接如何管理

假如把连接如何管理这个问题拆分一下，可以分解为两个问题：

（1）连接用什么数据结构管理？

（2）在一个 client 中可能会对多个下游发起调用，这里就会存在多种不同 server 的连接。那么多个 server 连接如何管理，是用一个连接池管理还是多个连接池管理？

针对第一个问题，对管理连接的数据结构的选择，可以有数组、链表、队列、channel 等进行管理。channel 是 go 里面特有的数据结构，能够天然用于 go 不同协程之间的通信。所以这里我们用 channel 来进行实现。当然你也可以使用其他数据结构，比如 redigo 就是用的双向链表实现。

针对第二个问题，不同类型的连接如何管理？假如是多个连接池管理的话，一种后端 server 地址一个连接池进行管理。这些连接池拥有一些相同的参数，比如初始连接数，最大连接数，空闲连接数，连接的空闲时间等。子连接池的结构如下所示：

```go
type channelPool struct {
   net.Conn
   initialCap int  // initial capacity
   maxCap int      // max capacity
   maxIdle int     // max idle conn number
   idleTimeout time.Duration  // idle timeout
   dialTimeout time.Duration  // dial timeout
   Dial func(context.Context) (net.Conn, error)
   conns chan *PoolConn
   mu sync.Mutex
}
```

这些参数的管理我们希望是统一化管理的，所以我们可以用一个大的连接池进行管理。用一个 map 来管理不同的 server 子连接池，map 的 key 是 server 的监听地址，value 是子连接池。所以，在子连接池 channelPool 的基础上，我们再定义一个全局 pool，结构如下：

```go
type pool struct {
   opts *Options
   conns *sync.Map
}
```

### 2、连接的创建和销毁

（1）连接什么时候创建？

连接的创建都是在子连接池里面进行。首先需要子连接池先初始化。假如用户设置了初始连接数 initialCap，例如 initialCap = 5，此时我们在创建子连接池的时候，就要初始化创建 5 个连接。那么子连接池什么时候初始化呢？因为一个子连接池对应一个后端 server 地址，这个地址参数只有在 client 发起调用时才会传入，所以在 client 调用 Get 方法获取连接 net.Conn 时，假如这个调用的后端 server 地址 address 是第一次调用，那么我们将会去初始化这个 address 的子连接池。

如下：

```go
func (p *pool) Get(ctx context.Context, network string, address string) (net.Conn, error) {

   if value, ok := p.conns.Load(address); ok {
      if cp, ok := value.(*channelPool); ok {
         conn, err := cp.Get(ctx)
         return conn, err
      }
   }

   cp, err := p.NewChannelPool(ctx, network, address)
   if err != nil {
      return nil, err
   }

   p.conns.Store(address, cp)

   return cp.Get(ctx)
}
```

上面这段逻辑是先从 map 中取出 key 为 address 的子连接池，假如不存在，那么说明是第一次调用，创建 后端 server 地址为 address 的子连接池，创建的核心逻辑如下：

```go
func (p *pool) NewChannelPool(ctx context.Context, network string, address string) (*channelPool, error){
   c := &channelPool {
      initialCap: p.opts.initialCap,
      maxCap: p.opts.maxCap,
      Dial : func(ctx context.Context) (net.Conn, error) {
         select {
         case <-ctx.Done():
            return nil, ctx.Err()
         default:
         }

         timeout := p.opts.dialTimeout
         if t , ok := ctx.Deadline(); ok {
            timeout = t.Sub(time.Now())
         }

         return net.DialTimeout(network, address, timeout)
      },
      conns : make(chan *PoolConn, p.opts.maxCap),
      idleTimeout: p.opts.idleTimeout,
      dialTimeout: p.opts.dialTimeout,
   }
   ...
   return c, nil
}
```

Dial 这个方法则是 client 向 server 发起后端调用的方法，要获取连接，最终还是调用 Dial 这个方法来得到一个连接。这里还引入了一个 context 进行上下文和超时控制。

所以我们就可以回答这个问题，子连接池初始化是在第一次 client 调用 pool.Get 方法获取连接的时候进行的。client 连接的创建是通过调用子连接池的 Dial 方法进行创建，创建时机也是在 pool.Get 的时候进行，子连接池初始化创建 address 地址的 server 连接个数由 initialCap 这个参数去指定。

（2）连接什么时候销毁

我们使用连接池的目的就是为了连接复用，那么问题来了，既然连接池里面的连接是复用的，是不是可以被无限使用下去呢？

答案肯定是否定的。那我们怎么判断一个连接什么时候该从连接池中销毁掉呢？这里首先需要明确一点，client 是不断发送请求，server 是不断进行请求监听，所以这里我们把对连接的状态管理放在了 client 端。server 端发现连接异常，则进行关闭，所以，连接池 pool 是被用在 client。

那么 pool 怎么知道什么时候该进行连接销毁呢？这里有两种情况。

第一种是连接已经 ”坏掉了“。这里 “坏掉了” 指的就是 server 关闭连接了，server 关闭连接，出现在 server 从 client 读写数据时，出现了异常，或者是出现了 io.EOF 这个错误，这个错误一般说明对端（client）已经关闭连接了。此时，说明这个连接是坏掉的，我们用一个标识 unusable 表明这个连接已经 ”坏掉“、不可用了。

第二种情况是连接已经闲置非常久了，因为我们为了实现连接复用和提高传输层效率，采用的是 tcp 长连接的方式。既然是长连接，假如这个连接已经很久没有被使用了，它也不会被关闭。这个时候 client 和 server 之间已经没有需要传输的数据了，我们为了避免资源浪费，就应该把这个连接给关闭，也就是销毁。

**解决方案**

针对第一种情况，非常好解决。我们只需要在进行读写数据时，发现出错了，就将连接置为不可用（unusable 设置为 true），并将连接关闭即可，如下：

```go
func (p *PoolConn) Read(b []byte) (int, error) {
   if p.unusable {
      return 0, ErrConnClosed
   }
   n, err := p.Conn.Read(b)
   if err != nil {
      p.MarkUnusable()
      p.Conn.Close()
   }
   return n, err
}

func (p *PoolConn) Write(b []byte) (int, error) {
   if p.unusable {
      return 0, ErrConnClosed
   }
   n, err := p.Conn.Write(b)
   if err != nil {
      p.MarkUnusable()
      p.Conn.Close()
   }
   return n, err
}
```

针对第二种情况，就相对复杂一点，这里我们采取的办法是 client 定时检查连接的状态，发现失效或者是闲置的连接，则进行销毁。这里是用一个独立的协程实现的，相当于健康检查。如下：

```go
// checker 函数负责校验连接是否存活
func (c *channelPool) RegisterChecker(internal time.Duration, checker func(conn *PoolConn) bool) {

	if internal <= 0 || checker == nil {
		return
	}

	go func() {

		for {

			time.Sleep(internal)

			length := len(c.conns)

			for i:=0; i < length; i++ {

				select {
				case pc := <- c.conns :

					if !checker(pc) {
						pc.MarkUnusable()
						pc.Close()
						break
					} else {
						c.Put(pc)
					}
				default:
					break
				}

			}
		}

	}()
}
```

checker 函数负责校验连接是否存活或者闲置，如下：

```go
func (c *channelPool) Checker (pc *PoolConn) bool {

   // check timeout
   if pc.t.Add(c.idleTimeout).Before(time.Now()) {
      return false
   }

   // check conn is alive or not
   if !isConnAlive(pc.Conn) {
      return false
   }

   return true
}
```

### 3、连接如何进行复用

连接不复用之前的请求流程是 client 通过 Dial 获取一个到指定 address 的连接 Conn。后续的请求用这个Conn 进行处理，处理完之后对这个连接 Conn 进行关闭。server 监听到一个连接后，用连接 Conn 处理请求、返回响应，然后把连接关闭。如下：

![img](/images/go-rpc/11-1.jpg)

那我们思考一下，假如需要进行连接复用，那么对于 client 而言，每次 conn 处理完之后，不能直接 Close，而是需要进行判断，假如连接是健康的，那么则需要把它加入我们的 channel 里面进行复用。对于 server 而言，由于 server 监听到一个请求，是循环进行读写的。只有在读写异常的时候进行连接 Conn 的关闭，所以这了只要 client 不关闭连接，且连接 Conn 是健康的，那么 server 就不会进行关闭。

所以这里的实现就是使用装饰者模式，对 Close 进行修饰，调用 Close 时，先判断 unusable 这个字段的值（假如连接异常 unusable 会被置为 true），假如 unusable 为 true（连接异常）则关闭，否则，则放入连接池中进行复用。如下：

```go
// overwrite conn Close for connection reuse
func (p *PoolConn) Close() error {
   p.mu.RLock()
   defer p.mu.RUnlock()

   if p.unusable {
      if p.Conn != nil {
         return p.Conn.Close()
      }
   }

   // reset connection deadline
   p.Conn.SetDeadline(time.Time{})

   return p.c.Put(p)
}
```

需要说明一下的是 PoolConn 这个结构体，它结构如下：

```go
type PoolConn struct {
   net.Conn
   c *channelPool
   unusable bool     // if unusable is true, the conn should be closed
   mu sync.RWMutex
   t time.Time  // connection idle time
   dialTimeout time.Duration // connection timeout duration
}
```

可以看到它是对原生连接 net.Conn 进行了修饰。它修饰了 net.Conn 的 Read、Write、Close 方法。Read 和 Write 上面也提到过，读失败会将 unusable 这个标志置为 true，表示连接异常，不可用了。写失败也会这样。同时在 Close 之前会判断 unusable 这个标志位，发现连接健康才会扔回池子里进行复用。

### 4、连接何时失效、何时关闭

在解决问题 1、2、3 的过程中，我们发现，其实问题 4 已经被解决了。连接在失效或者被闲置过久则关闭。

连接在读写失败或者发现对端关闭的时候失效，即将 unusable 置为 true，表示连接异常、不可用。

### 5、如何实现并发安全

由于我们是全局使用一个连接池对象来管理连接。那么这个连接池对象是所有协程共用的。这样就会牵涉到并发安全的问题。那么我们如何去实现并发安全呢？在 go 里面实现并发安全其实也比较简单，我们主要使用到互斥锁和并发安全的工具 sync.Map

（1）全局连接池对象 pool

全局连接池对象是所有协程共用的。它主要是实现对所有子连接池的统一管理，这里为了保证并发安全，通过一个并发安全的工具 sync.Map 来进行实现。

```go
type pool struct {
   opts *Options
   conns *sync.Map
}
```

（2）子连接池 channelPool

```go
type channelPool struct {
   net.Conn
   initialCap int  // initial capacity
   maxCap int      // max capacity
   maxIdle int     // max idle conn number
   idleTimeout time.Duration  // idle timeout
   dialTimeout time.Duration  // dial timeout
   Dial func(context.Context) (net.Conn, error)
   conns chan *PoolConn
   mu sync.Mutex
}
```

子连接池 pool 实现对某类 address 的 server 连接管理。这里主要是使用了互斥锁 sync.Mutex 来保证并发安全。所有的写操作都会进行加锁。

（3）具体的连接类 PoolConn

```go
type PoolConn struct {
   net.Conn
   c *channelPool
   unusable bool     // if unusable is true, the conn should be closed
   mu sync.RWMutex
   t time.Time  // connection idle time
   dialTimeout time.Duration // connection timeout duration
}
```

PoolConn 通过装饰者模式对原生连接 net.Conn 进行了修饰。这里也是通过互斥锁来保证并发安全，只不过这里粒度更细，用了读写锁 sync.RWMutex。

更多细节可以参考 [pool](https://github.com/lubanproj/gorpc/tree/master/pool/connpool)

### 小结

本章主要介绍了连接池 pool 的实现。包括对连接的管理、连接的创建和销毁、连接的复用、连接失效的健康检查以及如何实现并发安全等。本章内容较多，大家可以好好再详细梳理一下。