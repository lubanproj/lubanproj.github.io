---
title: "第二十章：认证鉴权实现"
date: 2020-02-20T00:00:00+08:00
draft: false
lesson: "go-rpc"
chapter: "chapter-20"
layout: "single"
canonical: "https://diu.life/lessons/go-rpc/auth/"
---

本章介绍 gorpc 认证鉴权的实现，本章主要介绍原理和部分代码实现，全部代码可以参考：[auth](https://github.com/lubanproj/gorpc/tree/master/auth)

在实现 gorpc 认证鉴权之前，我们需要了解一些认证鉴权方面的知识。

### 一、单体模式下的认证鉴权

在单体模式下，整个应用是一个进程，应用一般只需要一个统一的安全认证模块来实现用户认证鉴权。例如用户登陆时，安全模块验证用户名和密码的合法性。假如合法，为用户生成一个唯一的 Session。将 SessionId 返回给客户端，客户端一般将 SessionId 以 Cookie 的形式记录下来，并在后续请求中传递 Cookie 给服务端来验证身份。为了避免 Session Id被第三者截取和盗用，客户端和应用之前应使用 TLS 加密通信，session 也会设置有过期时间。

客户端访问服务端时，服务端一般会用一个拦截器拦截请求，取出 session id，假如 id 合法，则可判断客户端登陆。然后查询用户的权限表，判断用户是否具有执行某次操作的权限。

### 二、微服务模式下的认证鉴权

在微服务模式下，一个整体的应用可能被拆分为多个微服务，之前只有一个服务端，现在会存在多个服务端。对于客户端的单个请求，为保证安全，需要跟每个微服务都要重复上面的过程。这种模式每个微服务都要去实现相同的校验逻辑，肯定是非常冗余的。

#### 1、用户身份认证

为了避免每个服务端都进行重复认证，采用一个服务进行统一认证。所以考虑一个单点登录的方案，用户只需要登录一次，就可以访问所有微服务。一般在 api 的 gateway 层提供对外服务的入口，所以可以在 api gateway 层提供统一的用户认证。

#### 2、用户状态保持

由于 http 是一个无状态的协议，前面说到了单体模式下通过 cookie 保存用户状态， cookie 一般存储于浏览器中，用来保存用户的信息。但是 cookie 是有状态的。客户端和服务端在一次会话期间都需要维护 cookie 或者 sessionId，在微服务环境下，我们期望服务的认证是无状态的。所以我们一般采用 token 认证的方式，而非 cookie。

token 由服务端用自己的密钥加密生成，在客户端登录或者完成信息校验时返回给客户端，客户端认证成功后每次向服务端发送请求带上 token，服务端根据密钥进行解密，从而校验 token 的合法，假如合法则认证通过。token 这种方式的校验不需要服务端保存会话状态，方便服务扩展。

### 三、实现思路

由于业内比较通用的认证和鉴权方案比较类似，都是通过 tls 进行数据加密，通过 oauth2 进行权限校验。所以这里我们也是使用 tls + oauth2 的方式进行认证鉴权实现。这里不对 tls 和 oauth2 进行详细介绍，假如有不清楚的可以参考阮一峰老师的教程，介绍得比较清楚：

tls ：[www.ruanyifeng.com/blog/2014/0…](http://www.ruanyifeng.com/blog/2014/02/ssl_tls.html)

oauth2 ：[www.ruanyifeng.com/blog/2019/0…](http://www.ruanyifeng.com/blog/2019/04/oauth_design.html)

这里需要补充介绍下 tls 认证的两种方式：

**单向认证**：只有一个对象校验对端的证书合法性，通常是 client 校验 server 的证书合法性，例如：浏览器

**双向认证**：两端都相互校验证书合法性。client 校验 server 证书，server 也校验 client 证书。一般用于银行、金融等对安全级别要求比较高的网站或者客户端

框架默认支持单向认证。即 client 校验 server 证书。

接下来介绍下实现思路：

要支持 tls，需要 server 端提供证书（生产环境中一般需要 CA 签发），客户端在握手时根据 CA 的公钥来验证 server 端证书的合法性。使用 oauth2 进行权限控制，需要 client 在请求时带上 token，然后 server 去校验 token，验证 token 的正确性。这里 client 请求 token 可以在请求参数中透传，server 端对于 token 的处理，可以通过拦截器的方式进行实现。

**证书生成：**

第一步：服务端生成私钥

```go
openssl ecparam -genkey -name secp384r1 -out server.key
```

第二步：服务端使用私钥生成证书

```go
openssl req -new -x509 -sha256 -key server.key -out server.crt -days 3650
```

这里需要填写一些信息（Common Name 需要填写服务名）

```go
Country Name (2 letter code) []:
State or Province Name (full name) []:
Locality Name (eg, city) []:
Organization Name (eg, company) []:
Organizational Unit Name (eg, section) []:
Common Name (eg, fully qualified host name) []:testAuth
Email Address []:
```

上面生成了 server.crt 和 server.key 两个文件，我们将这两个文件放到 testdata 目录下

### 四、tls 认证实现

#### 1、接口定义

tls 认证鉴权是在传输层握手的时候进行认证，所以我们定义一个 TransportAuth 接口，这个接口包括了 client 和 server 握手的两个函数

```go
// TransportAuth defines a common interface for client and server handshakes
type TransportAuth interface {

   // ClientHandshake defines a common interface for client handshakes
   ClientHandshake(context.Context, string, net.Conn) (net.Conn, AuthInfo, error)

   // ServerHandshake defines a common interface for server handshakes
   ServerHandshake(conn net.Conn) (net.Conn, AuthInfo, error)

}
```

由于 go 官方包 "crypto/tls" 已经支持了 tls ，所以我们这里直接复用 "crypto/tls" 包的一些特性，主要是 tls 的配置 Config 和 连接状态 ConnectionState，

```go
// tlsAuth defines the implementation of TLS authentication
// and implements TransportAuth, PerRPCAuth, AuthInfo
type tlsAuth struct {
   config *tls.Config
   state tls.ConnectionState
}
```

这里的 Config 信息需要通过传入的证书来获取，如下：

```go
// NewClientTLSAuthFromFile instantiates client-side authentication information
// with certificates and service names
func NewClientTLSAuthFromFile(certFile, serverName string) (TransportAuth, error) {
   cert , err := ioutil.ReadFile(certFile)
   if err != nil {
      return nil, err
   }
   cp := x509.NewCertPool()
   if !cp.AppendCertsFromPEM(cert) {
      return nil, codes.ClientCertFailError
   }
   conf := &tls.Config {
      ServerName: serverName,
      RootCAs: cp,
   }
   return &tlsAuth{config : conf}, nil
}
```

#### 2、实现客户端握手

这里主要思路为，先从 tls 的配置信息 Config 中获取认证信息，然后 tls.Client 方法会返回一个带有认证信息的连接 conn，然后使用这个连接 conn 进行握手，而不是原来的连接。如下：

```go
// ClientHandshake implements the client's handshake
func (t *tlsAuth) ClientHandshake(ctx context.Context, authority string, rawConn net.Conn) (net.Conn, AuthInfo, error) {
   // 防止使用不同的 endpoints 时 ServerName 被污染
   cfg := cloneTLSConfig(t.config)
   if cfg.ServerName == "" {
      colonPos := strings.LastIndex(authority, ":")
      if colonPos == -1 {
         colonPos = len(authority)
      }
      cfg.ServerName = authority[:colonPos]
   }
   conn := tls.Client(rawConn, cfg)
   errChan := make(chan error, 1)

   go func() {
      errChan <- conn.Handshake()
   }()
   select {
   case err := <- errChan :
      if err != nil {
         return nil, nil, err
      }
   case <- ctx.Done() :
      return nil, nil, ctx.Err()
   }

   return WrapConn(rawConn,conn) , &tlsAuth{state : conn.ConnectionState()}, nil
}
```

#### 3、server 端握手实现

server 端握手实现和 client 端握手实现的思路类似，先从 tls 的配置信息 Config 中获取认证信息，然后调用 tls.Server 方法获取一个带有认证信息的连接 conn，使用这个新的 conn 进行握手。

```go
// the ServerHandshake implements the server handshake
func (t *tlsAuth) ServerHandshake(rawConn net.Conn) (net.Conn, AuthInfo, error) {
   conn := tls.Server(rawConn, t.config)
   if err := conn.Handshake(); err != nil {
      return nil, nil, err
   }
   return WrapConn(rawConn,conn), &tlsAuth{state : conn.ConnectionState()}, nil
}
```

#### 4、测试 tls 握手

测试 tls 握手的过程，这里不进行赘述，详情请参考代码：[auth_test](https://github.com/lubanproj/gorpc/blob/master/auth/auth_test.go)

### 五、oauth2 鉴权实现

oauth2 鉴权的实现也是主要用到了 "golang.org/x/oauth2" 这个包，之前上面说到了鉴权的思路：client 请求 token 可以在请求参数中透传，server 端对于 token 的处理，可以通过拦截器的方式进行实现。

#### 1、接口定义

我们定义一个接口 PerRPCAuth 来表示每次进行 rpc 请求都需要进行 token 认证，这里有一个 GetMetadata 方法，主要用来定义获取 token，可以继续看下面 oauth2 是怎么获取的。

```go
// PerRPCAuth defines a common interface for single RPC call authentication
type PerRPCAuth interface {

   // GetMetadata fetch custom metadata from the context
   GetMetadata(ctx context.Context, uri ... string) (map[string]string, error)

}
```

#### 2、oauth2 实现

oauth2 的实现主要是用到了 "golang.org/x/oauth2" 包的 Token 结构

```go
type oAuth2 struct {
   token *oauth2.Token
}
```

oauth2.Token 的结构不妨也贴一下：

```go
// Token represents the credentials used to authorize
// the requests to access protected resources on the OAuth 2.0
// provider's backend.
//
// Most users of this package should not access fields of Token
// directly. They're exported mostly for use by related packages
// implementing derivative OAuth2 flows.
type Token struct {
   // AccessToken is the token that authorizes and authenticates
   // the requests.
   AccessToken string `json:"access_token"`

   // TokenType is the type of token.
   // The Type method returns either this or "Bearer", the default.
   TokenType string `json:"token_type,omitempty"`

   // RefreshToken is a token that's used by the application
   // (as opposed to the user) to refresh the access token
   // if it expires.
   RefreshToken string `json:"refresh_token,omitempty"`

   // Expiry is the optional expiration time of the access token.
   //
   // If zero, TokenSource implementations will reuse the same
   // token forever and RefreshToken or equivalent
   // mechanisms for that TokenSource will not be used.
   Expiry time.Time `json:"expiry,omitempty"`

   // raw optionally contains extra metadata from the server
   // when updating a token.
   raw interface{}
}
```

实现了 GetMetadata 方法来进行 Token 的获取，如下：

```go
func (o *oAuth2) GetMetadata(ctx context.Context, uri ... string) (map[string]string, error) {

   if o.token == nil {
      return nil, codes.ClientCertFailError
   }

   return map[string]string{
      "authorization": o.token.Type() + " " + o.token.AccessToken,
   }, nil
}
```

#### 3、token 的透传

token 如何从 client 透传到 server 呢？这里主要通过 metadata，metadata 本质是一个 k-v 键值对

```go
type clientMetadata map[string][]byte

type serverMetadata map[string][]byte
```

我们在 gorpc 协议里面 Request 和 Response 都支持了这种键值对的透传，如下：

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

所以，我们只需要通过 oauth2 的 GetMetadata 获取 token 的 k-v 键值对，然后在 client 端发送请求的时候，塞到 Request 中，server 端收到请求，从 Request 取出 metadata，设置到 context 中，同时定义一个 authFunc，通过 authFunc 构造拦截器，从拦截器中取出 metadata，获取到 token 信息，然后校验 token 是否合法即可。如下：

通过 BuildAuthInterceptor，支持传入 AuthFunc 来构造一个 server 端拦截器。

```go
// AuthFunc verifies that the token is valid or not
type AuthFunc func(ctx context.Context) (context.Context, error)


// BuildAuthFilter constructs a client interceptor with an AuthFunc
func BuildAuthInterceptor(af AuthFunc) interceptor.ServerInterceptor {

   return func(ctx context.Context, req interface{}, handler interceptor.Handler) (interface{}, error) {
      newCtx, err := af(ctx)

      if err != nil {
         return nil, codes.NewFrameworkError(codes.ClientCertFail, err.Error())
      }

      return handler(newCtx, req)
   }
}
```

#### 4、全流程解析

**server 端**

业务需要定义一个 AuthFunc，这里面需要完成对 token 的校验。然后通过 gorpc.WithInterceptor(auth.BuildAuthInterceptor(af)) 来构造一个 server 端拦截器，对 rpc 请求进行拦截。

AuthFunc 中，先通过 md := metadata.ServerMetadata(ctx) 取出 metadata，然后从 metadata 中取出 token 信息，校验 token 信息是否合法。

```go
func main() {

   af := func(ctx context.Context) (context.Context, error){
      md := metadata.ServerMetadata(ctx)

      if len(md) == 0 {
         return ctx, errors.New("token nil")
      }
      v := md["authorization"]
      log.Debug("token : ", string(v))
      if string(v) != "Bearer testToken" {
         return ctx, errors.New("token invalid")
      }
      return ctx, nil
   }

   opts := []gorpc.ServerOption{
      gorpc.WithAddress("127.0.0.1:8003"),
      gorpc.WithNetwork("tcp"),
      gorpc.WithSerializationType("msgpack"),
      gorpc.WithTimeout(time.Millisecond * 2000000),
      gorpc.WithInterceptor(auth.BuildAuthInterceptor(af)),
   }
   s := gorpc.NewServer(opts ...)
   if err := s.RegisterService("/helloworld.Greeter", new(testdata.Service)); err != nil {
      panic(err)
   }
   s.Serve()
}
```

**client 端**

通过 client.WithPerRPCAuth 方法，传入一个 PerRPCAuth，这里通过调用 auth.NewOAuth2ByToken("testToken") 方法生成一个 token

```go
func main() {
   opts := []client.Option {
      client.WithTarget("127.0.0.1:8003"),
      client.WithNetwork("tcp"),
      client.WithTimeout(2000000 * time.Millisecond),
      client.WithSerializationType("msgpack"),
      client.WithPerRPCAuth(auth.NewOAuth2ByToken("testToken")),
   }
   c := client.DefaultClient
   req := &testdata.HelloRequest{
      Msg: "hello",
   }
   rsp := &testdata.HelloReply{}
   err := c.Call(context.Background(), "/helloworld.Greeter/SayHello", req, rsp, opts ...)
   fmt.Println(rsp.Msg, err)
}
```

我们看一下 NewOAuth2ByToken 这个方法，其实就是我们的 oauth2 包下的方法，它返回了一个 oAuth2 的对象，由于 oAuth2 实现了 PerRPCAuth 接口，所以可以通过 client.WithPerRPCAuth 直接设置每次 rpc 拦截的 token。

```go
// NewOAuth2ByToken supports the generation of an oauth2 based on a string token
func NewOAuth2ByToken(token string) *oAuth2 {
   return &oAuth2{
      token : &oauth2.Token{
         AccessToken: token,
      },
   }
}
```

这里还差了一步，需要将 PerRPCAuth 中的 token 数据，塞到 client 的 Request 里面。这一步在 client 构造 Request 的时候完成，如下：

```go
func addReqHeader(ctx context.Context, client *defaultClient, payload []byte) *protocol.Request {
   clientStream := stream.GetClientStream(ctx)

   servicePath := fmt.Sprintf("/%s/%s", clientStream.ServiceName, clientStream.Method)
   md := metadata.ClientMetadata(ctx)

   // fill the authentication information
   for _, pra := range client.opts.perRPCAuth {
      authMd, _ := pra.GetMetadata(ctx)
      for k, v := range authMd {
         md[k] = []byte(v)
      }
   }

   request := &protocol.Request{
      ServicePath: servicePath,
      Payload: payload,
      Metadata: md,
   }

   return request
}
```

至此，我们就完成了 client 到 server token 的透传、流转和校验。

具体代码可以参考我们的 example [auth](https://github.com/lubanproj/gorpc/tree/master/examples/auth)

### 小结

本章节主要介绍了认证鉴权的一些基础知识、模式和常用实现。并且使用 tls 和 oauth2 实现了 gorpc 框架的认证鉴权。需要读者自行了解一些认证鉴权的基础，否则可能有些吃力。