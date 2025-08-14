---
title: "第十三章：组件可插拔实现"
date: 2020-02-13T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-13"
layout: "single"
---

### 一、软件的可插拔性

在介绍框架的组件可插拔的实现之前，我们先介绍下软件的可插拔性。

什么叫软件的可插拔性呢？通俗一点的解释，顾名思义，就是某个模块插上去和不插上去都不影响系统的正常运行。插上去，某个功能就会被实现，拔掉，又不会影响系统的正常运作。

框架的可插拔性主要体现在两个方面：组件可插拔和插件可插拔。组件和插件的区别在于，组件是框架的重要组成部分，缺失了组件框架可能就无法正常运行。而插件是框架的加分项，缺失了插件框架一样能够正常运行，但是无法提供插件实现的具体能力。本章我们主要介绍组件的可插拔实现

### 二、组件可插拔实现

框架的组件主要包括 client、codec、log、pool、transport、metadata、selector 等。插件主要是集中在 plugin 这个模块。之前我们介绍各个组件的时候，都会说到每个组件都是可插拔、支持业务自定义的。那么具体是如何实现的呢？我们随便拿个组件来说吧，不妨就以 log 这个组件为例。

log 这个组件实现了一个轻便的日志打印的能力，支持不同日志级别。为了支持业务自定义，其实主要做了下面一些工作：

### 1、定义一套通用的标准接口

定义一套通用的标准接口，用来约束所有 log 组件都必须实现这一套接口，如下：

```go
type Log interface {
	Trace(format string, v ...interface{})
	Debug(format string, v ...interface{})
	Info(format string, v ...interface{})
	Warning(format string, v ...interface{})
	Error(format string, v ...interface{})
	Fatal(format string, v ...interface{})
}
```

Log 接口定义了日志组件标准，所有的日志组件都要实现 Trace、Debug、INFO、WARNING、ERROR、FATAL 这六个方法。

### 2、提供一个默认的实现

```go
type logger struct{
   *log.Logger
   options *Options
}
```

如下，我们定义 Logger 的默认实现 logger。它实现了 Log 接口的 Trace、Debug、INFO、WARNING、ERROR、FATAL 这六个方法。例如 Trace

```go
func (log *logger) Trace(format string, v ...interface{}) {
   if log.options.level > TRACE {
      return
   }
   data := log.Prefix() + fmt.Sprintf(format,v...)
   var buffer bytes.Buffer
   buffer.WriteString("[TRACE] ")
   buffer.WriteString(data)
   log.Output(3, buffer.String())
}
```

那我们调用的时候其实是直接通过 log.Trace 进行调用。所以这里其实还需要一层封装，这里的 Trace 方法对 logger 的 Trace 进行了封装，可以让用户用 [类名.方法名] 的方式调用，相当于 java 的静态方法。

```go
func Trace(format string, v ...interface{}) {
   DefaultLog.Trace(format, v...)
}
```

### 3、开放入口支持业务自定义

在 go 里面，首字母小写表示私有属性（相当于 java/c++ 中 private），首字母大写表示公用属性（相当于 java/c++ 中 public）。那么对于 DefaultLog ，假如不开放给用户修改的话，按照面向对象封装思想，应该定义为 defaultLog，但是，我们为了支持业务自定义，所以把这个属性给放开了，所以是首字母大写。它的定义如下：

```go
var DefaultLog = &logger {
   Logger : log.New(os.Stdout, "", log.LstdFlags|log.Lshortfile),
   options : &Options {
      level : 2,
   },
}
```

可以看到 DefaultLog 在程序编译时就已经初始化完毕。业务如果想要自定义 Log 实现，只需要在框架初始化时，更改 DefaultLog 的值即可，例如：

```go
func init() {
   log.DefaultLog = &log.Logger {}
}
```

### 三、第二种实现方式

上面提到了组件可插拔的一种实现。其实组件可插拔的实现还有一种更通用化的方式。

这种实现方式主要使用 map 来管理插件，利用了 go 特有的 init 函数，在框架初始化时进行插件的注册。我们以 codec 组件为例，来介绍这种实现方式。

### 1、定义一套通用的标准接口

跟第一种方式相同，我们定义一套标准接口，用来约束所有的 codec 组件都实现这个接口。

```go
type Codec interface {
   Encode([]byte) ([]byte, error)
   Decode([]byte) ([]byte, error)
}
```

我们前面介绍过了，codec 主要提供的能力是框架的编解码，我们的接口主要包括编码 Encode 和解码 Decode 这两个方法。

### 2、提供一个默认的实现

这一步跟第一种方式也相同，就不进行赘述，这里直接上代码，如下：

```go
type defaultCodec struct{}

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

func (c *defaultCodec) Decode(frame []byte) ([]byte,error) {
	return frame[FrameHeadLen:], nil
}
```

这里 defaultCodec 实现了 Encode 和 Decode 方法。

### 3、用 Map 管理某一类的插件，支持用户注册

这里直接使用一个 Map 进行管理所有的 codec 插件，同时提供一个 RegisterCodec 方法，这个方法是共有权限，可以支持业务调用来将插件添加到 codecMap 中。

```go
var codecMap = make(map[string]Codec)

func RegisterCodec(name string, codec Codec) {
	if codecMap == nil {
		codecMap = make(map[string]Codec)
	}
	codecMap[name] = codec
}
```

### 4、使用 init 函数进行插件注册

假如业务自定义了一个插件，需要在程序加载是就进行插件的注册，这怎么实现呢？go 的原生函数 init 可以帮助我们完美实现这个能力。

```go
func init() {
   RegisterCodec("proto", DefaultCodec)
}
```

init() 函数会在每个包完成初始化后自动执行，并且执行优先级比main函数高。所以我们可以用它来在程序运行前对插件进行注册。比如上面代码我们就注册了 proto 格式协议的编解码。

### 5、支持根据插件名字获取插件

假如我们现在注册了好几个插件，那我们在使用时如何选择哪个插件呢？这里就需要提供一个根据插件名获取插件的方法。由于我们的插件是使用 map 管理的，所以只需要传入插件名，我们就可以从插件 map 中获取到对应的插件了。如下：

```go
func GetCodec(name string) Codec {
   if codec, ok := codecMap[name]; ok {
      return codec
   }
   return DefaultCodec
}
```

比如框架 client 获取 codec 插件进行编码时使用如下：

```go
clientCodec := codec.GetCodec(c.opts.protocol)
...

reqbody, err := clientCodec.Encode(reqbuf)
```

### 小结

可插拔是软件设计的一种重要思想。在框架中，可插拔思想的实现主要包括组件可插拔和插件可插拔两块。本章主要介绍了两种实现组件可插拔的方式，下一章将介绍我们的插件体系。