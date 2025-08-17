---
title: "gRPC 源码阅读"
date: 2019-11-01T00:00:00+08:00
draft: false
lesson: "grpc-read"
layout: "single"
canonical: "https://diu.life/lessons/grpc-read/"
---

### 教程概览

gRPC 是 Google 开源的一款高性能、跨语言的 RPC 框架，基于 HTTP/2 协议和 Protocol Buffers 序列化技术。它在微服务架构中被广泛应用，提供了强大的服务间通信能力。

本教程将深入学习 gRPC 框架的源码实现，从基础概念到高级特性，包括 HTTP/2 协议、服务发现、负载均衡、认证鉴权、拦截器、协议编解码等核心机制的源码分析。通过系统性的源码阅读，帮助开发者深入理解 gRPC 的内部工作原理，提升对分布式系统和 RPC 框架的认知水平。

### 课程特色

- **源码导向**：以 gRPC-Go 源码为主线，深入分析核心实现机制
- **系统全面**：覆盖 gRPC 的各个核心组件和特性
- **实战结合**：通过 Hello World 示例逐步深入源码分析
- **循序渐进**：从基础概念到高级特性，层层递进

### 主要内容

- **基础概念**：gRPC 核心概念和 HTTP/2 协议基础
- **Hello World**：通过简单示例理解 gRPC 的基本使用
- **服务端分析**：深入分析 gRPC 服务端的启动和请求处理流程
- **客户端分析**：剖析 gRPC 客户端的连接建立和调用机制
- **服务发现**：了解 gRPC 的服务发现机制和实现
- **负载均衡**：分析 gRPC 的负载均衡策略和算法
- **认证鉴权**：学习 TLS 和 OAuth2 等认证机制的实现
- **拦截器**：理解 gRPC 拦截器的设计和使用
- **协议编解码**：深入分析 gRPC 的协议设计和编解码过程
- **数据流转**：全面了解 gRPC 中数据的流转过程

### 适合人群

- 有一定 Go 语言基础的开发者
- 对 RPC 框架和微服务架构感兴趣的工程师
- 希望深入理解 gRPC 内部机制的开发者
- 想要提升分布式系统设计能力的技术人员

### 章节预览

第一章：gRPC concepts & HTTP2  
第二章：gRPC hello world  
第三章：gRPC hello world server 解析  
第四章：gRPC hello world client 解析  
第五章：gRPC 服务发现  
第六章：gRPC 负载均衡  
第七章：gRPC 认证鉴权——TLS认证  
第八章：gRPC 认证鉴权——OAuth2认证  
第九章：gRPC 拦截器实现  
第十章：gRPC 协议编解码器  
第十一章：gRPC 协议解包过程全剖析  
第十二章：gRPC 数据流转