---
title: "第十章：日志模块实现"
date: 2020-02-10T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-10"
layout: "single"
---

### 一、log 库调研

要实现 log 模块，我们最容易想到的就是能不能直接使用第三方库。其实社区上的 log 组件是非常多的。在 github 上搜索一下 go log，看到排名靠前的组件有 logrus、zap、glog 等。

这里不妨先拿 logrus 来说吧，我们来看看它提供的一些特性：

- (1) 完全兼容 golang 标准库日志模块：logrus 拥有六种日志级别：debug、info、warn、error、fatal 和 panic，这是golang标准库日志模块的 API 的超集。如果你的项目使用标准库日志模块，完全可以以最低的代价迁移到logrus上。
- (2) 可扩展的 Hook 机制：允许使用者通过 hook 的方式将日志分发到任意地方，如本地文件系统、标准输出、logstash、elasticsearch 或者 mq 等，或者通过 hook 定义日志内容和格式等。
- (3) 可选的日志输出格式：logrus 内置了两种日志格式， `JSONFormatter` 和 `TextFormatter` ，如果这两个格式不满足需求，可以自己动手实现接口 `Formatter` ，来定义自己的日志格式。
- (4) Field机制：logrus 鼓励通过 Field 机制进行精细化的、结构化的日志记录，而不是通过冗长的消息来记录日志。
- (5) 线程安全性

其实仔细想想，我们可能需要的核心功能就两个：(1) 支持不同的日志级别 (5) 线程安全性支持

logrus 的 (2) (3) (4) 其实算是比较实用的功能，但是并非是刚需。对我自身而言，我更希望我的框架的日志库是一个轻量级、可插拔的。所以这里决定直接在 go 的 log 包的基础上进行封装实现。

### 二、基于 log 组件实现

技术选型确定了，接下来要做的核心无非就是实现日志级别和线程安全性，这里我们后面再讲，这里先进行基于 go 的 log 组件基础实现。

同样，先定义一套 Log 的接口，支持可插拔，方便业务自定义。

```go
type Log interface {
   Trace(format string, v ...interface{})
   Debug(format string, v ...interface{})
   INFO(format string, v ...interface{})
   WARNING(format string, v ...interface{})
   ERROR(format string, v ...interface{})
   FATAL(format string, v ...interface{})
}
```

然后定义 Log 接口的默认实现：

```go
type logger struct{
   *log.Logger
   options *Options
}

var defaultLog = &logger {
   Logger : log.New(os.Stdout, "", log.LstdFlags|log.Lshortfile),
   options : &Options {
      level : 2,
   },
}
```

这里有两点需要说明下，第一是使用了装饰者模式，对 go 原生的 log 组件的基础上增强了日志级别实现。这里使用组合而不是继承的方式，降低子类对父类的依赖。第二是这里使用了单例模式，defaultLog 是在编译时就进行了初始化，避免了频繁创建 log 对象的消耗。

### 三、日志级别的实现

对于日志级别的支持非常简单，我们先定义一套常用的日志级别，有低到高依次为：TRACE、DEBUG、INFO、WARNING、ERROR、FATAL

```go
const (
   NULL = iota
   TRACE = 1
   DEBUG = 2
   INFO = 3
   WARNGING = 4
   ERROR = 5
   FATAL = 6
)
```

Trace、Debug、INFO、WARNING、ERROR、FATAL 这六个方法都是平级的，我们只需要弄清楚一个方法里面是如何实现的就行了，就以 Debug 这个方法为例吧，如下：

```go
func (log *logger) Debug(format string, v ...interface{}) {
   if log.options.level > DEBUG {
      return
   }
   data := log.Prefix() + fmt.Sprintf(format,v...)
   var buffer bytes.Buffer
   buffer.WriteString("[DEBUG] ")
   buffer.WriteString(data)
   log.Output(3, buffer.String())
}
```

这里的核心实现就是一个 if 判断语句，这里的意思是假如发现日志级别比 DEBUG 高，这里就直接 return，也就是说后面的代码都不执行，Debug 的日志信息也就得不到打印。这里就实现了日志级别的控制。例如 level 为 INFO，因为 INFO > DEBUG，所以 Debug 日志就无法输出，将会输出 INFO、WARNGING、ERROR、FATAL 四种级别。

```go
if log.options.level > DEBUG {
   return
}
```

### 四、线程安全性的实现

还有一点非常重要，就是线程安全性。由于这里是单例模式，所以可能会存在多个协程同时占用 log 对象，进行资源竞争的现象。不过好消息就是 go 的原生 log 包就是线程安全的，我们来看看 log.Logger 的源码：

```go
type Logger struct {
   mu     sync.Mutex // ensures atomic writes; protects the following fields
   prefix string     // prefix to write at beginning of each line
   flag   int        // properties
   out    io.Writer  // destination for output
   buf    []byte     // for accumulating text to write
}
```

可以看到这里有 mu 这个变量，这个就是互斥锁。我们的写操作都是调用 Logger.Output 这个方法，我们看一下这个方法的源码

```go
func (l *Logger) Output(calldepth int, s string) error {
   now := time.Now() // get this early.
   var file string
   var line int
   l.mu.Lock()
   defer l.mu.Unlock()
   if l.flag&(Lshortfile|Llongfile) != 0 {
      // Release lock while getting caller info - it's expensive.
      l.mu.Unlock()
      var ok bool
      _, file, line, ok = runtime.Caller(calldepth)
      if !ok {
         file = "???"
         line = 0
      }
      l.mu.Lock()
   }
   l.buf = l.buf[:0]
   l.formatHeader(&l.buf, now, file, line)
   l.buf = append(l.buf, s...)
   if len(s) == 0 || s[len(s)-1] != '\n' {
      l.buf = append(l.buf, '\n')
   }
   _, err := l.out.Write(l.buf)
   return err
}
```

发现 Output 在进行写操作时，都会进行 Lock 加锁，所以这里是线程安全的。

```go
l.mu.Lock()
defer l.mu.Unlock()
```

所以，我们的 log 组件是基于 go 原生 log 实现，也是线程安全的。

核心原理就到这里，其他细节实现可以详见 [log](https://github.com/lubanproj/gorpc/tree/master/log)

### 小结

本小章主要是基于 go 原生组件 log 实现了一个轻量级、可插拔的 log 组件。重点介绍了日志级别和线程安全性的实现，其中涉及到了单例模式和装饰者模式的运用。