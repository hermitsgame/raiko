# Raiko 项目中文文档

本文档详细介绍 Raiko 项目的架构、工作原理以及部署方法。

## 目录

1. [SGX 的工作原理和在本项目中的应用](#1-sgx的工作原理和在本项目中的应用)
2. [Raiko 项目的架构分析和数据流程](#2-raiko项目的架构分析和数据流程)
3. [如何通过 Docker 搭建 Raiko 服务](#3-如何通过-docker-搭建-raiko-服务)

---

## 1. SGX 的工作原理和在本项目中的应用

### 1.1 Intel SGX 技术概述

**Intel Software Guard Extensions (SGX)** 是 Intel 开发的硬件级安全技术，旨在提供可信执行环境（TEE, Trusted Execution Environment）。SGX 的核心思想是在 CPU 内创建一个受保护的内存区域，称为 **Enclave（飞地）**，用于安全地执行代码和处理敏感数据。

#### 1.1.1 SGX 的核心特性

1. **内存加密与隔离**：
   - Enclave 内的代码和数据存储在特殊的内存区域（EPC - Enclave Page Cache）中
   - 即使具有 root 权限也无法访问 Enclave 内部的内容
   - 内存数据在离开 CPU 时会被加密

2. **远程证明（Remote Attestation）**：
   - SGX 提供机制证明代码在真实的、未被篡改的 Enclave 中运行
   - 通过生成 **Quote（证明文件）** 来验证 Enclave 的完整性
   - Quote 包含以下关键信息：
     - **MRENCLAVE**：Enclave 代码和数据的哈希值，用于验证 Enclave 内容是否被篡改
     - **MRSIGNER**：签名者标识符，用于验证 Enclave 的创建者身份
     - **REPORTDATA**：用户自定义数据，可用于绑定特定的密钥或状态信息
     - **ATTRIBUTES**：Enclave 的属性信息，包括调试标志等

3. **密封存储（Sealed Storage）**：
   - 允许 Enclave 将加密数据存储到磁盘
   - 只有相同的 Enclave（相同 MRENCLAVE）才能解密数据

### 1.2 Gramine：SGX 应用框架

**Gramine** 是一个开源库操作系统（LibOS），它将普通 Linux 应用程序转换为可以在 SGX Enclave 中运行的受保护应用程序，无需修改源代码。

#### 1.2.1 Gramine 的工作原理

1. **Manifest 配置文件**：
   - 定义应用程序在 SGX 中的运行环境
   - 指定文件系统挂载点、环境变量、受信任的文件等
   - Raiko 使用两种 manifest：
     - `sgx-guest.local.manifest.template`：本地运行配置
     - `sgx-guest.docker.manifest.template`：Docker 容器运行配置

2. **应用程序转换**：
   - Gramine 将普通二进制文件包装为可在 SGX 中运行的格式
   - 自动处理系统调用和内存管理
   - 支持远程证明配置（DCAP - Data Center Attestation Primitives）

3. **运行模式**：
   - **硬件模式**：在真实的 SGX 硬件上运行（`gramine-sgx`）
   - **直接模式（Direct Mode）**：在没有 SGX 硬件的环境中模拟运行（`gramine-direct`），用于开发和测试

### 1.3 Raiko 中 SGX 的应用架构

在 Raiko 项目中，SGX 用于生成区块链区块的加密证明，确保区块数据处理的正确性和完整性。

#### 1.3.1 组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Raiko Host (Host)                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          SGX Prover (LocalSgxProver)                 │  │
│  │  - 接收区块证明请求                                     │  │
│  │  - 调用 Gramine 执行 SGX Guest                         │  │
│  │  - 处理证明结果                                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                        │
                        │ 通过 Gramine 调用
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              SGX Enclave (Gramine + sgx-guest)               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              SGX Guest 应用程序                        │  │
│  │  1. Bootstrap：生成密钥对和 Quote                     │  │
│  │  2. Prove：处理区块数据并生成签名证明                  │  │
│  │  3. Aggregate：聚合多个区块证明                       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  受保护的操作：                                              │
│  - 私钥存储在加密的密封存储中                                │
│  - 区块数据处理在 Enclave 内完成                            │
│  - 生成 Quote 用于链上验证                                   │
└─────────────────────────────────────────────────────────────┘
```

#### 1.3.2 SGX 工作流程

**1. Bootstrap（初始化）阶段**

```rust
// 在 SGX Enclave 中执行
fn bootstrap() {
    // 1. 生成新的密钥对（secp256k1）
    let key_pair = generate_key();
    
    // 2. 将私钥加密存储到密封存储（基于 MRENCLAVE）
    save_priv_key(&key_pair, &privkey_path);
    
    // 3. 计算公钥地址（Ethereum 地址格式）
    let new_instance = public_key_to_address(&key_pair.public_key());
    
    // 4. 将实例地址存储到 REPORTDATA（用于远程证明）
    save_attestation_user_report_data(new_instance);
    
    // 5. 获取 SGX Quote
    let quote = get_sgx_quote();
    
    // 6. 保存 Bootstrap 信息（公钥、地址、Quote）
    save_bootstrap_details(&key_pair, new_instance, quote);
}
```

**关键点**：
- 私钥在 Enclave 内生成，从未暴露给外部
- 私钥使用基于 MRENCLAVE 的密钥加密存储，只有相同代码的 Enclave 才能解密
- Quote 包含公钥地址信息，用于链上注册和验证

**2. Prove（证明生成）阶段**

```rust
// 在 SGX Enclave 中执行
async fn one_shot(input: GuestInput, instance_id: u64) {
    // 1. 从密封存储加载私钥
    let prev_privkey = load_bootstrap(&secrets_dir)?;
    
    // 2. 计算区块头
    let header = calculate_block_header(&input);
    
    // 3. 创建协议实例并计算哈希
    let pi = ProtocolInstance::new(&input, &header, ProofType::Sgx)?
        .sgx_instance(new_instance);
    let pi_hash = pi.instance_hash();
    
    // 4. 使用私钥对哈希进行签名
    let sig = sign_message(&prev_privkey, pi_hash)?;
    
    // 5. 构建证明数据：instance_id(4B) + instance_address(20B) + signature(65B) = 89B
    let proof = [
        instance_id.to_be_bytes(),  // 链上注册的实例 ID
        new_instance,               // 公钥地址
        sig                         // 签名
    ].concat();
    
    // 6. 获取当前 Quote（用于验证）
    let quote = get_sgx_quote();
    
    // 7. 返回证明和 Quote
    return { proof, quote, input: pi_hash };
}
```

**关键点**：
- 区块数据处理在 Enclave 内完成，确保完整性
- 使用私钥签名，证明处理是由可信的 SGX 实例执行的
- Quote 允许链上验证者确认代码未被篡改

**3. 远程证明（Remote Attestation）流程**

```
┌─────────────┐                    ┌──────────────┐
│   Raiko     │                    │  链上验证器    │
│  (Prover)   │                    │  (Verifier)  │
└──────┬──────┘                    └──────┬───────┘
       │                                  │
       │ 1. Bootstrap                    │
       │    生成 Quote                    │
       ├─────────────────────────────────>│
       │                                  │
       │ 2. 注册实例                       │
       │    (包含 Quote)                  │
       ├─────────────────────────────────>│
       │                                  │
       │                    ┌─────────────┤
       │                    │ 验证 Quote  │
       │                    │ - MRENCLAVE │
       │                    │ - MRSIGNER  │
       │                    │ - FMSPC     │
       │                    └─────────────┤
       │                                  │
       │ 3. 返回实例 ID                   │
       │<─────────────────────────────────┤
       │                                  │
       │ 4. Prove                         │
       │    生成 Proof + Quote            │
       ├─────────────────────────────────>│
       │                                  │
       │                    ┌─────────────┤
       │                    │ 验证：       │
       │                    │ 1. Quote   │
       │                    │ 2. 签名     │
       │                    │ 3. 实例ID   │
       │                    └─────────────┤
       │                                  │
       │ 5. 验证结果                       │
       │<─────────────────────────────────┤
```

#### 1.3.3 安全机制

**1. 密钥管理**
- 私钥在 Enclave 内生成，永远不离开 Enclave
- 使用 Gramine 的加密文件系统存储，基于 MRENCLAVE 加密
- 只有相同代码版本的 Enclave 才能解密（MRENCLAVE 匹配）

**2. 代码完整性验证**
- Quote 中的 MRENCLAVE 确保代码未被篡改
- 链上验证器检查 MRENCLAVE 是否在允许列表中
- MRSIGNER 验证代码由可信的开发者签名

**3. 实例绑定**
- 每个 SGX 实例通过 Bootstrap 生成唯一的密钥对
- 实例地址（公钥）存储在 Quote 的 REPORTDATA 中
- 链上注册时绑定实例地址和 Quote
- 证明中包含实例 ID 和地址，确保证明来自已注册的实例

**4. 平台验证（FMSPC）**
- FMSPC（Fused Microcode Package ID）标识特定的硬件平台
- Raiko 仅支持特定 FMSPC 的平台（如：00606A000000）
- 这确保只在经过验证的硬件平台上运行

**如何确认当前机器的 FMSPC：**

确认 FMSPC 需要使用 `PCKIDRetrievalTool` 工具和 Intel PCS Service API。

**方法一：使用一键命令（推荐）**

1. 安装 `PCKIDRetrievalTool`：

```bash
echo "deb [arch=amd64] https://download.01.org/intel-sgx/sgx_repo/ubuntu focal main" | sudo tee /etc/apt/sources.list.d/intel-sgx.list > /dev/null
wget -O - https://download.01.org/intel-sgx/sgx_repo/ubuntu/intel-sgx-deb.key | sudo apt-key add -
sudo apt update
sudo apt install sgx-pck-id-retrieval-tool
```

2. 获取 FMSPC（需要 Intel PCS Service API Key）：

```bash
echo "Please enter Intel's PCS Service API key" && read -r API_KEY && PCKIDRetrievalTool -f /tmp/pckid.csv && pckid=$(cat /tmp/pckid.csv) && ppid=$(echo "$pckid" | awk -F "," '{print $1}') && cpusvn=$(echo "$pckid" | awk -F "," '{print $3}') && pcesvn=$(echo "$pckid" | awk -F "," '{print $4}') && pceid=$(echo "$pckid" | awk -F "," '{print $2}') && curl -v "https://api.trustedservices.intel.com/sgx/certification/v4/pckcert?encrypted_ppid=${ppid}&cpusvn=${cpusvn}&pcesvn=${pcesvn}&pceid=${pceid}" -H "Ocp-Apim-Subscription-Key:${API_KEY}" 2>&1 | grep -i "SGX-FMSPC"
```

执行后会输出类似：`< SGX-FMSPC: 00606A000000`，其中 `00606A000000` 就是你的 FMSPC。

**方法二：分步操作**

1. 运行 `PCKIDRetrievalTool` 生成机器信息：

```bash
PCKIDRetrievalTool
```

成功后会生成 `pckid_retrieval.csv` 文件，包含以下信息：
- EncryptedPPID（384 字节 BE 字节数组）
- PCE_ID（LE 16 位整数）
- CPUSVN（16 字节 BE 字节数组）
- PCE ISVSVN（LE 16 位整数）
- QE_ID（16 字节 BE 字节数组）

2. 使用 Intel API 查询 FMSPC：

```bash
curl -v "https://api.trustedservices.intel.com/sgx/certification/v4/pckcert?encrypted_ppid={EncryptedPPID}&cpusvn={CPUSVN}&pcesvn={PCE_ISVSVN}&pceid={PCE_ID}" -H "Ocp-Apim-Subscription-Key:{YOUR_API_KEY}"
```

将命令中的 `{}` 替换为从 `pckid_retrieval.csv` 获取的对应值，`{YOUR_API_KEY}` 替换为你的 Intel PCS Service API Key。

响应头中的 `SGX-FMSPC` 字段即为你的 FMSPC 值。

**注意：**
- 需要先订阅 [Intel PCS Service](https://www.intel.com/content/www/us/en/developer/articles/guide/intel-software-guard-extensions-data-center-attestation-primitives-quick-install-guide.html) 获取 API Key
- 如果机器的 FMSPC 不在 Raiko 支持列表中，请创建 GitHub Issue 申请添加支持

#### 1.3.4 本地 SGX Prover 实现

Raiko 提供两种 SGX Prover：

1. **LocalSgxProver**：本地执行 SGX Guest 程序
2. **RemoteSgxProver**：通过 HTTP API 调用远程 SGX 服务

LocalSgxProver 的核心实现流程：

```rust
impl Prover for LocalSgxProver {
    async fn run(&self, input: GuestInput, ...) -> ProverResult<Proof> {
        // 1. 检查运行模式（硬件/SGX_DIRECT模拟）
        let direct_mode = env::var("SGX_DIRECT") == Ok("1");
        
        // 2. 准备 Gramine 命令
        let gramine_cmd = if direct_mode {
            cmd!("gramine-direct", ELF_NAME)  // 模拟模式
        } else {
            cmd!("sudo", "gramine-sgx", ELF_NAME)  // 硬件模式
        };
        
        // 3. 执行 SGX Guest 程序
        //    - Setup：生成 manifest 和签名（首次运行）
        //    - Bootstrap：生成密钥和 Quote（首次运行）
        //    - Prove：处理区块并生成证明
        let output = gramine_cmd
            .arg("one-shot")
            .arg("--sgx-instance-id")
            .arg(instance_id.to_string())
            .stdin_bytes(serialize(input)?)
            .run()?;
        
        // 4. 解析返回的证明
        parse_sgx_result(output.stdout)
    }
}
```

#### 1.3.5 Quote 的结构和验证

SGX Quote（V3 ECDSA 格式）包含以下关键字段：

```
Quote Structure:
├── Header (48 bytes)
│   ├── Version
│   ├── Attestation Key Type (ECDSA-256)
│   ├── TEE Type (SGX)
│   └── ...
├── Enclave Report (384 bytes)
│   ├── CPUSVN (16 bytes)
│   ├── Attributes (16 bytes)
│   ├── MRENCLAVE (32 bytes) ← 代码完整性哈希
│   ├── MRSIGNER (32 bytes) ← 签名者标识
│   ├── ISVPRODID (2 bytes)
│   ├── ISVSVN (2 bytes)
│   └── REPORTDATA (64 bytes) ← 包含实例地址
└── Authentication Data
    ├── ECDSA Signature (64 bytes)
    ├── ECDSA Attestation Key (64 bytes)
    ├── QE Report (384 bytes)
    └── Certification Data
        └── PCK Certificate Chain
```

**链上验证流程**：

1. **解析 Quote**：提取 MRENCLAVE、MRSIGNER、REPORTDATA 等字段
2. **验证签名**：使用 Intel 的根证书验证 Quote 签名
3. **检查 MRENCLAVE**：确认代码版本匹配
4. **检查 MRSIGNER**：确认开发者身份可信
5. **检查 FMSPC**：确认硬件平台受支持
6. **提取实例地址**：从 REPORTDATA 中获取绑定的实例地址
7. **验证实例 ID**：确认实例已注册且 ID 匹配

### 1.4 总结

SGX 在 Raiko 项目中的应用提供了以下安全保障：

1. **可信计算**：区块数据处理在受硬件保护的环境中执行
2. **密钥安全**：私钥生成、存储、使用都在 Enclave 内完成
3. **完整性证明**：通过 Quote 证明代码未被篡改
4. **身份绑定**：实例地址与 Quote 绑定，确保证明来源可信
5. **平台验证**：只允许在已验证的硬件平台上运行

这些机制共同确保了 Raiko 生成的区块证明是可信的，可以被链上验证器安全地接受。

---

## 2. Raiko 项目的架构分析和数据流程

### 2.1 项目概述

**Raiko** 是 Taiko 协议的**多证明器（Multi-Prover）**，用于为 Taiko 和 Ethereum 区块生成密码学证明。Raiko 支持多种证明系统：
- **Native**：原生执行，不生成密码学证明（用于开发测试）
- **SGX**：基于 Intel SGX 硬件的可信执行环境证明
- **SP1**：基于 SP1 zkVM 的零知识证明
- **RISC0**：基于 RISC0 zkVM 的零知识证明

Raiko 采用**异步请求处理架构**，通过 HTTP API 接收证明请求，在后台异步处理并返回结果。

### 2.2 系统架构

```
┌─────────────────────────────────────────────────────────────┐
│                    客户端 (Client)                            │
│  - 发送区块证明请求                                           │
│  - 查询证明状态                                              │
└────────────────────┬────────────────────────────────────────┘
                     │ HTTP/HTTPS
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  HTTP 服务器层                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Axum Web Server                                      │  │
│  │  - 路由分发 (/v1, /v2, /v3)                          │  │
│  │  - 认证中间件 (API Key / JWT)                        │  │
│  │  - CORS、压缩、日志等中间件                           │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  请求处理层 (Handler)                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  proof_handler()                                      │  │
│  │  - 解析请求配置                                        │  │
│  │  - 构建 RequestKey + RequestEntity                    │  │
│  │  - 调用 Actor 系统                                     │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Actor 系统                                 │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Actor                                                │  │
│  │  - 管理请求状态 (Pool)                                │  │
│  │  - 将请求加入队列 (Queue)                            │  │
│  │  - 唤醒后台 Worker                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Pool (Redis/内存)                                     │  │
│  │  - 存储请求状态: RequestKey → Status                  │  │
│  │  - 状态: Registered → Proving → Success/Failed       │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Queue                                                 │  │
│  │  - 任务队列 (有大小限制)                               │  │
│  │  - 状态: pending → processing → completed             │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                  后台处理层 (Backend)                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Backend Worker                                        │  │
│  │  - 从队列获取请求                                      │  │
│  │  - 控制并发数量 (Semaphore)                           │  │
│  │  - 调用证明生成逻辑                                    │  │
│  │  - 更新 Pool 状态                                      │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                   核心证明层 (Core)                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Raiko                                                │  │
│  │  1. generate_input() - 生成区块输入数据                │  │
│  │  2. get_output() - 计算区块输出                       │  │
│  │  3. prove() - 生成证明                                │  │
│  └──────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  BlockDataProvider                                    │  │
│  │  - RPC 数据提供者 (从链节点获取区块数据)                │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│                   证明器层 (Provers)                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │   SGX    │  │   SP1    │  │  RISC0   │  │  Native  │   │
│  │  Prover  │  │  Prover  │  │  Prover  │  │  Prover  │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 核心模块说明

#### 2.3.1 Host (`host/`)

**职责**：HTTP 服务器和请求入口
- **主要组件**：
  - `server/`：HTTP 路由和处理器
  - `bin/main.rs`：程序入口，初始化系统
- **功能**：
  - 启动 Axum HTTP 服务器
  - 处理 HTTP 请求（认证、路由、限流）
  - 调用 Actor 系统处理证明请求
  - 提供健康检查、指标、API 文档等接口

#### 2.3.2 Core (`core/`)

**职责**：核心证明生成逻辑
- **主要组件**：
  - `lib.rs`：Raiko 主结构体
  - `preflight/`：区块数据预处理
  - `provider/`：区块数据提供者接口
- **核心方法**：
  ```rust
  // 生成区块输入数据（从 RPC 获取并处理）
  async fn generate_input(provider) -> GuestInput
  
  // 计算区块输出（执行交易并生成区块头）
  fn get_output(input: &GuestInput) -> GuestOutput
  
  // 生成证明（调用相应的 Prover）
  async fn prove(input, output) -> Proof
  ```

#### 2.3.3 Lib (`lib/`)

**职责**：共享库，定义核心数据结构和算法
- **主要模块**：
  - `builder/`：区块构建器（基于 Reth EVM）
  - `input/`：证明输入数据结构（GuestInput, GuestBatchInput）
  - `prover/`：证明器接口定义
  - `protocol_instance/`：协议实例哈希计算
  - `consts/`：链规格配置（ChainSpec）

#### 2.3.4 Reqactor (`reqactor/`)

**职责**：异步请求处理系统
- **主要组件**：
  - `actor.rs`：请求处理前端接口
  - `backend.rs`：后台处理 Worker
  - `queue.rs`：任务队列管理
- **工作模式**：
  - **Actor**：接收请求，更新状态，加入队列
  - **Backend**：从队列取任务，异步处理，更新状态

#### 2.3.5 Reqpool (`reqpool/`)

**职责**：请求状态存储
- **实现方式**：
  - Redis 存储（生产环境）
  - 内存存储（开发环境）
- **存储内容**：
  - `RequestKey` → `(RequestEntity, StatusWithContext)`
  - 支持状态查询和更新

#### 2.3.6 Provers (`provers/`)

**职责**：各种证明器的实现
- **SGX Prover** (`provers/sgx/`)：
  - `prover/`：Host 端 SGX Prover 接口
  - `guest/`：SGX Enclave 内执行的程序
- **SP1 Prover** (`provers/sp1/`)：
  - `builder/`：构建 SP1 证明
  - `driver/`：SP1 驱动接口
- **RISC0 Prover** (`provers/risc0/`)：
  - `builder/`：构建 RISC0 证明
  - `driver/`：RISC0 驱动接口

#### 2.3.7 Ballot (`ballot/`)

**职责**：证明类型选择器
- **功能**：根据区块哈希随机选择证明类型（用于 `zk_any` 模式）
- **使用场景**：确保证明类型的去中心化分布

### 2.4 数据流程

#### 2.4.1 系统启动流程

```
main()
  ├─> parse_opts()              # 解析命令行参数和配置文件
  ├─> parse_chain_specs()       # 解析链规格配置（支持的网络）
  ├─> parse_ballot()             # 解析证明类型选择器配置
  ├─> Pool::open()               # 打开 Redis 连接池（或内存存储）
  ├─> start_actor()              # 启动 Actor 系统
  │   ├─> 创建 Queue（任务队列）
  │   ├─> 创建 Actor（请求处理接口）
  │   ├─> 创建 Backend（后台处理 Worker）
  │   └─> 启动后台循环（Backend.serve_in_background()）
  └─> serve()                    # 启动 HTTP 服务器
```

#### 2.4.2 HTTP 请求处理流程

**阶段 1：请求接收**

```
HTTP POST /v3/proof
    ↓
[认证中间件]
    ├─> 提取 X-API-KEY Header
    ├─> 验证 API Key 有效性
    ├─> 检查速率限制
    └─> 将认证信息存入 Request Extensions
    ↓
[路由分发]
    ├─> /v3/proof → proof_handler()
    └─> 其他路由（报告、管理、健康检查等）
    ↓
[HTTP Handler]
    ├─> 解析请求体（JSON）
    ├─> 合并配置（客户端配置 + 默认配置）
    ├─> 构建 RequestKey（chain_id, block_number, blockhash）
    └─> 构建 RequestEntity（包含所有请求参数）
```

**阶段 2：请求提交到 Actor**

```
proof_handler()
    ↓
prove() 或 prove_aggregation()
    ↓
actor.act(request_key, request_entity, start_time)
    ├─> 检查 Pool 中是否已有此请求
    │   └─> [已存在且成功?] → 直接返回成功状态
    ├─> 标记请求状态为 Registered
    ├─> [请求不存在?]
    │   ├─> 是 → pool_add_new()  # 添加到 Pool
    │   └─> 否 → pool_update_status()  # 更新状态
    ├─> 尝试加入队列 (Queue.add_pending)
    │   └─> [队列已满?] → 更新状态为 Failed
    ├─> 唤醒后台 Worker (notify.notify_one())
    └─> 立即返回 Status::Registered  # 异步处理
```

**阶段 3：后台异步处理**

```
Backend.serve_in_background() (循环)
    ↓
处理已完成的请求
    └─> 从完成通道接收 → queue.complete()
    ↓
获取信号量许可 (控制并发数)
    ↓
从队列获取下一个请求 (queue.try_next())
    ├─> [队列为空?] → 等待通知
    └─> 获取到请求
        ↓
异步 spawn 处理任务
    ├─> 根据请求类型分发：
    │   ├─> SingleProof → do_prove_single()
    │   ├─> Aggregation → do_prove_aggregation()
    │   ├─> BatchProof → do_prove_batch()
    │   └─> GuestInput → do_generate_guest_input()
    │
    └─> 处理完成后：
        ├─> 更新 Pool 状态 (Success/Failed)
        └─> 发送完成通知
```

#### 2.4.3 单区块证明生成流程

```
do_prove_single()
    ↓
1. 获取链配置 (chain_specs)
    └─> 根据 network 和 l1_network 获取 ChainSpec
    ↓
2. 创建 Raiko 实例
    └─> Raiko::new(l1_chain_spec, taiko_chain_spec, proof_request)
    ↓
3. 创建 RpcBlockDataProvider
    └─> 连接到区块链节点 RPC
    ↓
4. 生成 GuestInput
    ├─> 检查是否已有 guest_input（客户端提供）
    └─> [无?] → raiko.generate_input(provider)
        └─> preflight() 处理区块数据
            ├─> 从 RPC 获取区块数据
            ├─> 获取 L1 状态证明（Merkle Proof）
            ├─> 构建 GuestInput 结构
            └─> 包含：block, chain_spec, taiko 相关数据等
    ↓
5. 获取 GuestOutput
    └─> raiko.get_output(&input)
        ├─> 创建内存数据库 (create_mem_db)
        ├─> 创建区块构建器 (RethBlockBuilder)
        ├─> 执行交易 (execute_transactions)
        ├─> 完成区块构建 (finalize)
        ├─> 验证区块头 (check_header)
        └─> 返回 GuestOutput { header, hash }
    ↓
6. 生成证明
    └─> raiko.prove(input, &output, pool)
        ├─> 根据 proof_type 选择 Prover
        │   ├─> SGX → SgxProver::run()
        │   ├─> SP1 → Sp1Prover::run()
        │   ├─> RISC0 → Risc0Prover::run()
        │   └─> Native → 直接返回（无证明）
        └─> 返回 Proof 对象
    ↓
7. 更新状态
    └─> pool.update_status(request_key, Status::Success { proof })
```

#### 2.4.4 批量证明流程

```
do_prove_batch()
    ↓
1. 解析批量请求
    └─> 提取 batch_id 和 l2_block_numbers
    ↓
2. 生成批量输入
    └─> raiko.generate_batch_input(provider)
        └─> batch_preflight()
            ├─> 从 L1 批量提案交易中提取所有区块号
            ├─> 获取所有区块的数据
            └─> 构建 GuestBatchInput { inputs: Vec<GuestInput> }
    ↓
3. 获取批量输出
    └─> raiko.get_batch_output(&batch_input)
        ├─> 为每个区块执行交易
        ├─> 验证区块间的父子关系
        └─> 返回 GuestBatchOutput { blocks, hash }
    ↓
4. 生成批量证明
    └─> raiko.batch_prove(batch_input, &batch_output, pool)
        └─> BatchProver::run()
            └─> 生成单个证明覆盖所有区块
    ↓
5. 更新状态
    └─> pool.update_status(request_key, Status::Success { proof })
```

#### 2.4.5 聚合证明流程

```
do_prove_aggregation()
    ↓
1. 从请求实体提取子证明
    └─> 所有子请求的 Proof 对象
    ↓
2. 构建聚合输入
    └─> AggregationGuestInput { proofs: Vec<Proof> }
    ↓
3. 计算聚合输出哈希
    └─> AggregationGuestOutput { hash }
    ↓
4. 调用聚合证明器
    └─> aggregate_proofs(proof_type, input, &output, config)
        ├─> SGX → 验证签名链并生成聚合签名
        ├─> SP1 → 递归证明聚合
        └─> RISC0 → 类似处理
    ↓
5. 更新状态
    └─> pool.update_status(request_key, Status::Success { proof })
```

#### 2.4.6 状态查询流程

```
GET /proof/report?chain_id=...&block_number=...&blockhash=...
    ↓
report_handler()
    ↓
构建 RequestKey
    └─> 从查询参数提取 chain_id, block_number, blockhash
    ↓
actor.pool_get_status(request_key)
    ↓
从 Pool 查询状态
    └─> 返回：
        - Registered：已注册，等待处理
        - Proving：正在处理中
        - Success { proof }：成功，包含证明
        - Failed { error }：失败，包含错误信息
    ↓
返回 JSON 响应给客户端
```

### 2.5 数据结构和接口

#### 2.5.1 核心数据结构

**GuestInput**：证明输入数据
```rust
pub struct GuestInput {
    pub block: Block,                    // 区块数据
    pub chain_spec: ChainSpec,       // 链规格
    pub taiko: TaikoProverData,      // Taiko 特定数据
    pub l1_header: Header,           // L1 区块头
    pub l1_proof: MerkleProof,        // L1 状态证明
    // ...
}
```

**GuestOutput**：证明输出数据
```rust
pub struct GuestOutput {
    pub header: Header,               // 计算出的区块头
    pub hash: B256,                   // 协议实例哈希
}
```

**Proof**：证明结果
```rust
pub struct Proof {
    pub proof: Option<String>,        // 证明数据（十六进制编码）
    pub input: Option<B256>,          // 输入哈希
    pub quote: Option<String>,        // SGX Quote（SGX 专用）
    pub uuid: Option<String>,         // 证明 UUID
    pub kzg_proof: Option<String>,    // KZG 证明（可选）
}
```

**RequestKey**：请求标识符
```rust
pub enum RequestKey {
    SingleProof(SingleProofRequestKey {
        chain_id: u64,
        block_number: u64,
        blockhash: B256,
    }),
    BatchProof(BatchProofRequestKey { /* ... */ }),
    Aggregation(AggregationRequestKey { /* ... */ }),
}
```

#### 2.5.2 API 接口

**V3 API（推荐使用）**

```
POST /v3/proof
Content-Type: application/json

{
  "network": "taiko_a7",
  "l1_network": "holesky",
  "blocks": [
    { "block_number": 1000000 }
  ],
  "proof_type": "sgx",
  "graffiti": "0x...",
  "prover": "0x...",
  "sgx": {
    "instance_id": 1,
    "setup": false,
    "bootstrap": false,
    "prove": true
  }
}

响应：
{
  "status": "ok",
  "proof_type": "sgx",
  "data": {
    "status": "registered"  // 或 "success" 包含 proof
  }
}
```

**状态查询**

```
GET /proof/report?chain_id=167009&block_number=1000000&blockhash=0x...

响应：
{
  "status": "success",
  "proof_type": "sgx",
  "data": {
    "status": "success",
    "proof": {
      "proof": "0x...",
      "quote": "0x...",
      "input": "0x..."
    }
  }
}
```

### 2.6 关键设计特点

1. **异步非阻塞架构**：
   - HTTP 请求立即返回，证明在后台异步处理
   - 客户端通过状态查询接口获取结果

2. **状态持久化**：
   - 使用 Pool（Redis/内存）存储请求状态
   - 支持系统重启后恢复请求状态

3. **并发控制**：
   - 使用 Semaphore 控制同时处理的证明数量
   - 防止系统资源耗尽

4. **队列管理**：
   - 使用 Queue 管理待处理请求
   - 有大小限制，防止内存溢出

5. **幂等性**：
   - 相同请求（相同的 RequestKey）可以直接返回已有结果
   - 避免重复计算

6. **多证明器支持**：
   - 统一的 Prover 接口
   - 支持动态选择证明类型

7. **认证和授权**：
   - 支持 API Key 和 JWT 两种认证方式
   - API Key 级别的速率限制

### 2.7 数据流向图

```
┌──────────┐
│ 客户端   │
│ 发送请求 │
└────┬─────┘
     │ HTTP POST /v3/proof
     ▼
┌─────────────────────┐
│  HTTP 服务器         │
│  - 认证              │
│  - 路由              │
│  - 解析请求          │
└────┬────────────────┘
     │
     ▼
┌─────────────────────┐
│  Actor              │
│  - 更新 Pool (Registered) │
│  - 加入 Queue        │
│  - 唤醒 Worker       │
└────┬────────────────┘
     │ 立即返回 Status::Registered
     │
     ├──────────────────┐
     │                  │
     ▼                  ▼
┌─────────────┐  ┌──────────────┐
│  客户端查询  │  │ Backend      │
│  状态       │  │ Worker       │
│             │  │              │
│  GET /report│  │ 从 Queue 取任务│
└─────────────┘  │ 生成证明      │
                 │ 更新 Pool     │
                 └───────────────┘
                          │
                          ▼
                 ┌──────────────┐
                 │  Core         │
                 │  - generate_input│
                 │  - get_output │
                 │  - prove      │
                 └──────┬────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │  Prover      │
                 │  (SGX/SP1/...)│
                 └──────────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │  Proof        │
                 │  返回给客户端 │
                 └──────────────┘
```

---

## 3. 如何通过 Docker 搭建 Raiko 服务

本部分详细说明如何在支持 SGX 的机器上，使用 Docker 搭建一个针对本地 devnet (127.0.0.1:8545) 的 Raiko 服务，使用真实的 SGX 硬件和本地 SGX Prover。

### 3.1 前置要求

#### 3.1.1 硬件要求

1. **Intel SGX 支持的 CPU**：
   - 确保 CPU 支持 Intel SGX（Software Guard Extensions）
   - 在 BIOS 中启用 SGX
   - 验证命令：
     ```bash
     cpuid | grep -i sgx
     # 或
     grep sgx /proc/cpuinfo
     ```

2. **系统要求**：
   - Linux 内核版本 ≥ 6.0（支持 EDMM）
   - Docker 已安装
   - 推荐配置：4 核 CPU、8GB 内存（最低 2 核、4GB）

3. **EPC 内存**：
   - 推荐 4GB Enclave Page Cache（防止 OOM）
   - 检查命令：`./script/check-epc-size.sh`

#### 3.1.2 软件依赖

1. **Gramine**：SGX 应用框架
   - 已包含在 Docker 镜像中

2. **Intel SGX 驱动和工具**：
   ```bash
   # 安装 SGX 驱动（如果未安装）
   sudo apt-get update
   sudo apt-get install -y \
       libsgx-enclave-common \
       libsgx-urts \
       libsgx-dcap-ql \
       libsgx-dcap-default-qpl \
       sgx-pck-id-retrieval-tool
   ```

3. **Intel PCS 服务订阅**（用于 ECDSA 远程证明）：
   - 访问 [Intel PCS 服务](https://www.intel.com/content/www/us/en/developer/articles/guide/intel-software-guard-extensions-data-center-attestation-primitives-quick-install-guide.html)
   - 订阅服务并获取 API Key（主密钥和备用密钥）

### 3.2 配置 PCCS（Provisioning Certificate Caching Service）

PCCS 用于缓存 Intel 的 PCK 证书和其他证明相关数据。

#### 3.2.1 生成 SSL 证书

```bash
# 创建配置目录
mkdir -p ~/.config/sgx-pccs
cd ~/.config/sgx-pccs

# 生成私钥
openssl genrsa -out private.pem 2048
chmod 644 private.pem

# 生成证书签名请求
openssl req -new -key private.pem -out csr.pem
# 按提示填写信息（可直接回车使用默认值）

# 生成自签名证书
openssl x509 -req -days 365 -in csr.pem -signkey private.pem -out file.crt

# 清理临时文件
rm csr.pem
```

#### 3.2.2 配置 PCCS

```bash
# 下载默认配置文件
curl -s https://raw.githubusercontent.com/taikoxyz/raiko/refs/heads/main/docs/default.json \
    > ~/.config/sgx-pccs/default.json

# 编辑配置文件
vi ~/.config/sgx-pccs/default.json
```

配置文件中需要设置以下参数：

```json
{
  "ApiKey": "YOUR_INTEL_API_KEY",           // 从 Intel PCS 服务获取
  "UserTokenHash": "SHA512_HASH_OF_USER_PASSWORD",
  "AdminTokenHash": "SHA512_HASH_OF_ADMIN_PASSWORD",
  "hosts": "0.0.0.0"
}
```

**生成 Token Hash**：
```bash
# User Token Hash
echo -n "your_user_password" | sha512sum | tr -d '[:space:]-'

# Admin Token Hash
echo -n "your_admin_password" | sha512sum | tr -d '[:space:]-'
```

**设置文件权限**：
```bash
chmod 644 ~/.config/sgx-pccs/default.json
chmod 644 ~/.config/sgx-pccs/file.crt
chmod 644 ~/.config/sgx-pccs/private.pem
```

### 3.3 准备 Raiko 配置目录

```bash
# 创建 Raiko 配置目录
mkdir -p ~/.config/raiko/config
mkdir -p ~/.config/raiko/secrets

# 创建日志目录
sudo mkdir -p /var/log/raiko
sudo chmod 777 /var/log/raiko
```

### 3.4 SGX_MODE：Local vs Remote 模式详解

在配置 Raiko 之前，需要理解 `SGX_MODE` 两种模式的区别，以便选择最适合的部署方式。

#### 3.4.1 Local 模式（本地模式）

**工作原理**：
- Raiko Host 进程直接调用本地的 `gramine-sgx` 命令执行 SGX Guest 程序
- SGX Enclave 与 Raiko Host 在同一个容器/进程中运行
- 通过进程调用直接通信，无网络开销

**架构图**：
```
┌─────────────────────────────────────┐
│      Raiko Host 容器                 │
│  ┌──────────────────────────────┐   │
│  │  Raiko HTTP Server           │   │
│  └──────────┬───────────────────┘   │
│             │                        │
│  ┌──────────▼───────────────────┐   │
│  │  LocalSgxProver              │   │
│  │  ┌──────────────────────┐   │   │
│  │  │ gramine-sgx           │   │   │
│  │  │   └─> sgx-guest      │   │   │
│  │  └──────────────────────┘   │   │
│  └──────────────────────────────┘   │
└─────────────────────────────────────┘
        │
        ▼ 直接进程调用
┌─────────────────────────────────────┐
│      SGX Enclave (硬件)              │
│  - 密钥存储                          │
│  - 区块处理                          │
│  - 签名生成                          │
└─────────────────────────────────────┘
```

**优势**：
1. ✅ **零网络延迟**：进程内调用，通信延迟极低
2. ✅ **简单部署**：单个容器即可运行，无需额外的 SGX 服务器
3. ✅ **资源效率**：无需维护独立的 SGX 服务器进程
4. ✅ **调试方便**：所有日志集中在一个容器中
5. ✅ **默认模式**：开箱即用，配置简单

**劣势**：
1. ❌ **可扩展性受限**：每个 Raiko 实例需要独立的 SGX 硬件
2. ❌ **资源竞争**：HTTP 服务和 SGX 证明生成共享 CPU/内存
3. ❌ **无法横向扩展**：无法将证明生成任务分发到多个 SGX 服务器

**适用场景**：
- 单机部署或小规模部署
- 开发测试环境
- 对延迟敏感的应用
- 资源有限的场景

#### 3.4.2 Remote 模式（远程模式）

**工作原理**：
- Raiko Host 通过 HTTP API 调用远程的 SGX 服务器（`raiko-sgx-server`）
- SGX Enclave 运行在独立的容器中
- 多个 Raiko Host 实例可以共享同一个 SGX 服务器

**架构图**：
```
┌─────────────────────────────────────┐  HTTP API      ┌─────────────────────────────────────┐
│   Raiko Host 容器（多个实例）          │  ───────────► │   SGX Server 容器                    │
│  ┌──────────────────────────────┐   │                │  ┌──────────────────────────────┐   │
│  │  Raiko HTTP Server            │   │                │  │  RemoteSgxProver            │   │
│  └──────────┬───────────────────┘   │                │  │  ┌──────────────────────┐   │   │
│             │                        │                │  │  │ gramine-sgx           │   │   │
│  ┌──────────▼───────────────────┐   │                │  │  │   └─> sgx-guest      │   │   │
│  │  RemoteSgxProver              │   │                │  │  └──────────────────────┘   │   │
│  │  ┌──────────────────────┐    │   │                │  └──────────────────────────────┘   │
│  │  │ HTTP Client           │    │   │                └─────────────────────────────────────┘
│  │  │ POST /prove/block     │    │   │                            │
│  │  └──────────────────────┘    │   │                            ▼
│  └──────────────────────────────┘   │                ┌─────────────────────────────────────┐
└─────────────────────────────────────┘                │      SGX Enclave (硬件)              │
                                                       │  - 密钥存储                          │
                                                       │  - 区块处理                          │
                                                       │  - 签名生成                          │
                                                       └─────────────────────────────────────┘
```

**配置示例**：
```yaml
# docker-compose.yml
services:
  raiko:
    environment:
      - SGX_MODE=remote
      - RAIKO_REMOTE_URL=http://raiko-sgx-server:9090
      - GAIKO_REMOTE_URL=http://raiko-sgx-server:8090
  
  raiko-sgx-server:
    environment:
      - SGX_SERVER=true
    ports:
      - "9090:9090"  # SGX 证明服务
      - "8090:8090"  # Gaiko 服务
```

**优势**：
1. ✅ **可扩展性强**：多个 Raiko Host 可以共享同一个 SGX 服务器
2. ✅ **资源隔离**：HTTP 服务和 SGX 证明生成分离，互不干扰
3. ✅ **横向扩展**：可以部署多个 SGX 服务器实现负载均衡
4. ✅ **集中管理**：SGX 密钥和配置集中在一个服务器上
5. ✅ **灵活性**：可以单独升级或重启 SGX 服务器而不影响 HTTP 服务

**劣势**：
1. ❌ **网络延迟**：HTTP 请求增加额外的网络延迟
2. ❌ **复杂部署**：需要同时运行 Raiko Host 和 SGX Server 两个容器
3. ❌ **网络依赖**：依赖网络连接，可能受到网络问题影响
4. ❌ **资源消耗**：需要额外的容器和进程资源

**适用场景**：
- 大规模生产部署
- 需要多个 Raiko 实例共享 SGX 资源
- 需要将证明生成服务独立部署
- 需要实现高可用和负载均衡

#### 3.4.3 模式对比总结

| 特性 | Local 模式 | Remote 模式 |
|------|-----------|------------|
| **部署复杂度** | 简单（单容器） | 复杂（多容器） |
| **延迟** | 极低（进程内调用） | 中等（HTTP 请求） |
| **可扩展性** | 受限 | 优秀 |
| **资源隔离** | 共享资源 | 独立资源 |
| **横向扩展** | 不支持 | 支持 |
| **适用规模** | 小到中型 | 大型生产环境 |
| **默认值** | ✅ 是 | 否 |
| **网络依赖** | 无 | 有 |

#### 3.4.4 选择建议

- **选择 Local 模式**，如果：
  - 单机部署或资源有限
  - 对延迟非常敏感
  - 简单的开发测试环境
  - 不需要多实例共享 SGX 资源

- **选择 Remote 模式**，如果：
  - 大规模生产环境
  - 需要多个 Raiko 实例
  - 需要独立的 SGX 服务
  - 需要实现负载均衡和高可用

### 3.5 配置 Devnet 环境

#### 3.5.1 创建 .env 文件

在 `raiko/docker/` 目录下创建 `.env` 文件：

```bash
cd /nvme/dev/prove/raiko/docker
cat > .env << 'EOF'
# SGX 配置
SGX=true
SGXGETH=false                    # 对于 devnet，可以设为 false
SGX_MODE=remote                  # 使用远程 SGX Prover（详见 3.4 节说明）
SGX_DIRECT=0                     # 0 = 使用真实 SGX 硬件，1 = 模拟模式（测试用）

# 网络配置
NETWORK=taiko_dev                # devnet 网络名称
L1_NETWORK=taiko_dev_l1          # devnet L1 网络名称

# RPC 配置（指向本地 devnet）
TAIKO_A7_RPC=http://127.0.0.1:8545    # 本地 devnet RPC
HOLESKY_RPC=http://127.0.0.1:8545    # 如果需要（devnet 可能不需要）
ETHEREUM_RPC=http://127.0.0.1:8545    # 如果需要

# Remote SGX 服务配置（Remote 模式必需）
RAIKO_REMOTE_URL=http://raiko-sgx-server:9090    # SGX 证明服务地址
GAIKO_REMOTE_URL=http://raiko-sgx-server:8090    # Gaiko 服务地址（如果使用 SGXGETH）

# SGX Instance ID（需要在 Bootstrap 后设置）
SGX_PACAYA_INSTANCE_ID=0          # 初始值，Bootstrap 后会更新
SGXGETH_PACAYA_INSTANCE_ID=0      # 如果使用 SGXGETH

# Redis 配置
REDIS_URL=redis://redis:6379
ENABLE_REDIS_POOL=true

# 日志配置
RUST_LOG=info

# PCCS 配置（可选，默认使用容器内的 PCCS）
# PCCS_HOST=pccs:8081
EOF
```

**注意**：使用 Remote 模式时，需要确保：
1. `RAIKO_REMOTE_URL` 指向运行 `raiko-sgx-server` 服务的地址
2. 在同一个 Docker 网络中，可以使用服务名 `raiko-sgx-server`
3. 如果 SGX 服务器在外部，使用实际 IP 或域名

#### 3.5.2 准备配置文件

创建 devnet 的配置文件：

```bash
# 复制默认 SGX 配置
cp ../host/config/config.sgx.json ~/.config/raiko/config/config.sgx.json

# 编辑配置文件以适配 devnet
vi ~/.config/raiko/config/config.sgx.json
```

配置文件内容示例：

```json
{
  "network": "taiko_dev",
  "l1_network": "taiko_dev_l1",
  "graffiti": "0000000000000000000000000000000000000000000000000000000000000000",
  "sgx": {
    "instance_ids": {
      "HEKLA": 0,
      "ONTAKE": 0,
      "PACAYA": 0,
      "SHANGHAI": 0
    },
    "setup": true,
    "bootstrap": true,
    "prove": true,
    "input_path": null
  }
}
```

**注意**：
- `setup: true` - 首次运行需要设置 Gramine manifest
- `bootstrap: true` - 首次运行需要生成密钥和 Quote
- `prove: true` - 运行证明生成

### 3.6 启动服务

#### 3.6.1 拉取 Docker 镜像

```bash
cd /nvme/dev/prove/raiko/docker

# 拉取 Raiko 镜像（或使用本地构建）
docker pull us-docker.pkg.dev/evmchain/images/raiko:latest
docker pull us-docker.pkg.dev/evmchain/images/pccs:latest

# 或者构建本地镜像
docker compose build
```

#### 3.6.2 Bootstrap SGX 实例

首次运行需要执行 Bootstrap 来生成密钥和 Quote：

**对于 Remote 模式**：
- Bootstrap 可以在 SGX Server 启动后通过 API 调用完成
- 或者先使用 Local 模式执行 Bootstrap，然后切换到 Remote 模式

**方式 1：通过 Remote API Bootstrap（推荐）**

```bash
# 1. 先启动 SGX Server
docker compose up raiko-sgx-server -d

# 2. 等待服务就绪
sleep 10

# 3. 通过 API 调用 Bootstrap
curl -X POST http://localhost:9090/bootstrap
```

**方式 2：通过 init 容器 Bootstrap（兼容）**

```bash
# 临时使用 Local 模式进行 Bootstrap
# 修改 .env 文件，设置 SGX_MODE=local
# 然后执行：
docker compose up init

# Bootstrap 完成后，将 .env 改回 SGX_MODE=remote
```

**检查 Bootstrap 结果**：
```bash
# 检查生成的文件
ls -la ~/.config/raiko/config/
# 应该看到 bootstrap.json 文件

# 查看 Bootstrap 信息
cat ~/.config/raiko/config/bootstrap.json
```

Bootstrap 输出示例：
```json
{
  "public_key": "0x02ab85f14dcdc93832f4bb9b40ad908a5becb840d36f64d21645550ba4a2b28892",
  "new_instance": "0xc369eedf4c69cacceda551390576ead2383e6f9e",
  "quote": "0x030002..."
}
```

**注意**：Remote 模式下，Bootstrap 在 SGX Server 容器中执行，生成的文件存储在共享的 volume `~/.config/raiko/` 中。

#### 3.6.3 配置链规格文件

如果 devnet 使用了自定义的链规格，需要创建或修改链规格文件：

```bash
# 查看默认链规格文件
cat ../host/config/chain_spec_list_devnet.json

# 如果需要修改 RPC 地址，可以在 entrypoint.sh 中自动更新
# 或者直接修改文件
vi ~/.config/raiko/config/chain_spec_list_devnet.json
```

#### 3.6.4 启动 Raiko 服务（Remote 模式）

由于使用 Remote 模式，需要同时启动 SGX Server 和 Raiko Host：

```bash
# 方式 1: 启动所有必需服务（推荐）
# 首先启动 SGX Server
docker compose up raiko-sgx-server -d

# 等待 SGX Server 就绪（约 10 秒）
sleep 10

# 检查 SGX Server 状态
docker compose logs raiko-sgx-server | grep "Listening on"

# 然后启动 Raiko Host（使用 prod-redis profile 包含 Redis）
docker compose --profile prod-redis up raiko -d

# 方式 2: 一次性启动所有服务
docker compose --profile prod-redis up raiko-sgx-server raiko -d
```

**验证服务启动**：
```bash
# 检查所有容器状态
docker compose ps

# 查看 SGX Server 日志（确认服务正常监听）
docker compose logs raiko-sgx-server

# 应该看到类似输出：
# Listening on: 0.0.0.0:9090  (SGX 证明服务)
# Listening on: 0.0.0.0:8090  (Gaiko 服务，如果启用)

# 查看 Raiko Host 日志
docker compose logs raiko

# 应该看到类似输出：
# sgx mode: Remote, prove_type: Sgx
# Listening on http://0.0.0.0:8080
```

**查看日志**：
```bash
# 查看所有服务日志
docker compose logs -f

# 单独查看 Raiko Host 日志
docker compose logs -f raiko

# 单独查看 SGX Server 日志
docker compose logs -f raiko-sgx-server
```

**重要提示**：
- Remote 模式下，必须确保 `raiko-sgx-server` 先启动并正常运行
- Raiko Host 启动时会通过 `RAIKO_REMOTE_URL` 连接 SGX Server
- 如果 SGX Server 未运行，Raiko Host 将无法生成证明

### 3.7 验证服务

#### 3.7.1 检查服务状态

```bash
# 检查所有容器状态（Remote 模式应看到 raiko 和 raiko-sgx-server 两个容器）
docker compose ps

# 检查 Raiko Host 服务健康状态
curl http://localhost:8080/health

# 检查 SGX Server 服务（如果支持健康检查）
curl http://localhost:9090/check

# 检查服务指标
curl http://localhost:8080/metrics
```

#### 3.7.2 测试证明生成

```bash
# 发送证明请求
curl -X POST http://localhost:8080/v3/proof \
  -H "Content-Type: application/json" \
  -d '{
    "network": "taiko_dev",
    "l1_network": "taiko_dev_l1",
    "blocks": [
      { "block_number": 1 }
    ],
    "proof_type": "sgx",
    "graffiti": "0x0000000000000000000000000000000000000000000000000000000000000000",
    "prover": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "sgx": {
      "instance_id": 0,
      "setup": false,
      "bootstrap": false,
      "prove": true
    }
  }'

# 查询证明状态
curl "http://localhost:8080/proof/report?chain_id=167000&block_number=1&blockhash=0x..."
```

**预期响应**：
```json
{
  "status": "ok",
  "proof_type": "sgx",
  "data": {
    "status": "registered"  // 或 "success" 包含 proof
  }
}
```

### 3.8 常见问题排查

#### 3.8.1 SGX 设备未找到

**错误信息**：`/dev/sgx_enclave` 或 `/dev/sgx_provision` 不存在

**解决方案**：
```bash
# 检查 SGX 设备
ls -la /dev/sgx*

# 如果不存在，安装 SGX 驱动
sudo apt-get install -y libsgx-enclave-common libsgx-urts

# 重启 aesmd 服务
sudo systemctl restart aesmd
```

#### 3.8.2 PCCS 连接失败

**错误信息**：无法连接到 PCCS 服务

**解决方案**：
```bash
# 检查 PCCS 容器是否运行
docker compose ps pccs

# 检查 PCCS 日志
docker compose logs pccs

# 验证 PCCS 配置
cat ~/.config/sgx-pccs/default.json

# 检查证书文件权限
ls -la ~/.config/sgx-pccs/

# Remote 模式下，检查 SGX Server 是否能连接到 PCCS
docker compose exec raiko-sgx-server curl http://pccs:8081/sgx/certification/v4/tcb
```

#### 3.8.3 Bootstrap 失败

**错误信息**：Bootstrap 过程中出错

**解决方案**：
```bash
# Remote 模式：检查 SGX Server 容器中的 SGX 设备访问权限
docker compose exec raiko-sgx-server ls -la /dev/sgx*

# 查看 SGX Server 日志（Remote 模式）
docker compose logs raiko-sgx-server

# 或者查看 init 容器日志（如果使用 init 容器 Bootstrap）
docker compose logs init

# 确保在真实的 SGX 硬件上运行（SGX_DIRECT=0）
# 如果只是测试，可以设置 SGX_DIRECT=1 使用模拟模式

# Remote 模式：验证 Bootstrap API 是否可访问
curl -X POST http://localhost:9090/bootstrap -v
```

#### 3.8.4 无法连接到 Devnet RPC

**错误信息**：无法连接到 127.0.0.1:8545

**解决方案**：
```bash
# 确保本地 devnet 节点正在运行
curl http://127.0.0.1:8545

# 如果 devnet 运行在 Docker 中，需要使用 host.docker.internal
# 修改 .env 文件：
TAIKO_A7_RPC=http://host.docker.internal:8545

# 或者在 docker-compose.yml 中添加：
extra_hosts:
  - "host.docker.internal:host-gateway"
```

#### 3.8.6 Remote 模式连接问题

**错误信息**：无法连接到 SGX Server 或 `Connection refused`

**解决方案**：
```bash
# 1. 检查 SGX Server 是否运行
docker compose ps raiko-sgx-server

# 2. 检查 SGX Server 日志
docker compose logs raiko-sgx-server

# 3. 验证 SGX Server 是否监听在正确的端口
docker compose exec raiko-sgx-server netstat -tlnp | grep -E '9090|8090'

# 4. 检查网络连通性（在 Raiko Host 容器中）
docker compose exec raiko curl http://raiko-sgx-server:9090/check

# 5. 验证环境变量
docker compose exec raiko env | grep RAIKO_REMOTE_URL
docker compose exec raiko env | grep GAIKO_REMOTE_URL

# 6. 确保两个容器在同一个 Docker 网络中
docker network ls
docker inspect <network_name> | grep -A 10 raiko
```

#### 3.8.5 Quote 验证失败

**错误信息**：Quote 验证失败或 MRENCLAVE 不匹配

**解决方案**：
```bash
# 检查 Quote 信息
docker exec raiko cat ~/.config/raiko/config/bootstrap.json | jq .quote

# 确认使用的是正确版本的镜像
# 不同的镜像版本会有不同的 MRENCLAVE

# 如果更换了代码或镜像，需要重新 Bootstrap
rm ~/.config/raiko/secrets/priv.key
docker compose up init
```

### 3.9 生产环境建议

1. **使用外部 Redis**：
   - 避免使用容器内的 Redis
   - 配置持久化存储
   - 设置适当的 TTL

2. **监控和日志**：
   - 配置日志轮转
   - 设置 Prometheus 监控
   - 配置告警

3. **安全配置**：
   - 使用 HTTPS
   - 配置 API Key 认证
   - 限制网络访问

4. **性能优化**：
   - 调整并发数量（`concurrency_limit`）
   - 优化 RPC 连接池
   - 使用高速 RPC 节点

### 3.10 完整部署脚本示例

以下是一个完整的部署脚本示例：

```bash
#!/bin/bash
set -e

# 配置变量
RAIKO_DIR="/nvme/dev/prove/raiko"
DEVNET_RPC="http://127.0.0.1:8545"
INTEL_API_KEY="YOUR_API_KEY"

echo "=== 步骤 1: 检查 SGX 硬件 ==="
if ! grep -q sgx /proc/cpuinfo; then
    echo "错误: CPU 不支持 SGX 或未在 BIOS 中启用"
    exit 1
fi

echo "=== 步骤 2: 配置 PCCS ==="
mkdir -p ~/.config/sgx-pccs
cd ~/.config/sgx-pccs

if [ ! -f file.crt ]; then
    openssl genrsa -out private.pem 2048
    chmod 644 private.pem
    openssl req -new -key private.pem -out csr.pem
    openssl x509 -req -days 365 -in csr.pem -signkey private.pem -out file.crt
    rm csr.pem
fi

if [ ! -f default.json ]; then
    curl -s https://raw.githubusercontent.com/taikoxyz/raiko/refs/heads/main/docs/default.json \
        > default.json
    
    # 设置 API Key
    sed -i "s/\"ApiKey\": \".*\"/\"ApiKey\": \"${INTEL_API_KEY}\"/" default.json
    
    # 设置 hosts
    sed -i 's/"hosts": ".*"/"hosts": "0.0.0.0"/' default.json
fi

echo "=== 步骤 3: 准备 Raiko 配置 ==="
mkdir -p ~/.config/raiko/{config,secrets}
sudo mkdir -p /var/log/raiko
sudo chmod 777 /var/log/raiko

cd ${RAIKO_DIR}/docker

# 创建 .env 文件
cat > .env << EOF
SGX=true
SGXGETH=false
SGX_MODE=remote
SGX_DIRECT=0
NETWORK=taiko_dev
L1_NETWORK=taiko_dev_l1
TAIKO_A7_RPC=${DEVNET_RPC}
RAIKO_REMOTE_URL=http://raiko-sgx-server:9090
GAIKO_REMOTE_URL=http://raiko-sgx-server:8090
REDIS_URL=redis://redis:6379
ENABLE_REDIS_POOL=true
RUST_LOG=info
EOF

# 复制配置文件
cp ../host/config/config.sgx.json ~/.config/raiko/config/

echo "=== 步骤 4: 启动 PCCS 服务 ==="
docker compose up -d pccs
sleep 5

echo "=== 步骤 5: 启动 SGX Server 并 Bootstrap ==="
docker compose up raiko-sgx-server -d
sleep 10

# 验证 SGX Server 是否正常启动
if docker compose ps raiko-sgx-server | grep -q "Up"; then
    echo "✅ SGX Server 启动成功"
else
    echo "❌ SGX Server 启动失败，查看日志："
    docker compose logs raiko-sgx-server
    exit 1
fi

# 通过 API Bootstrap（或使用 init 容器）
# 方式 1: API Bootstrap
echo "执行 Bootstrap..."
if curl -X POST http://localhost:9090/bootstrap > /dev/null 2>&1; then
    echo "✅ 通过 API Bootstrap 成功"
else
    echo "⚠️  API Bootstrap 失败，尝试使用 init 容器"
    # 临时切换为 local 模式进行 Bootstrap
    sed -i 's/SGX_MODE=remote/SGX_MODE=local/' .env
    docker compose up init
    sed -i 's/SGX_MODE=local/SGX_MODE=remote/' .env
fi

# 检查 Bootstrap 结果
sleep 5
if [ ! -f ~/.config/raiko/config/bootstrap.json ]; then
    echo "错误: Bootstrap 失败"
    exit 1
fi

echo "=== 步骤 7: 启动 Raiko Host 服务 ==="
docker compose --profile prod-redis up raiko -d

echo "=== 步骤 8: 验证服务 ==="
sleep 10

# 验证 SGX Server
if curl -s http://localhost:9090/check > /dev/null 2>&1; then
    echo "✅ SGX Server API 可访问"
else
    echo "⚠️  SGX Server API 检查失败（可能是正常的，取决于实现）"
fi

# 验证 Raiko Host
if curl -s http://localhost:8080/health > /dev/null; then
    echo "✅ Raiko Host 服务启动成功！"
    echo "访问 http://localhost:8080 查看 API 文档"
    echo "SGX Server 运行在 http://localhost:9090"
else
    echo "❌ Raiko Host 服务启动失败，查看日志："
    docker compose logs raiko
    exit 1
fi
```

### 3.11 总结

通过以上步骤，您已经成功搭建了一个针对本地 devnet 的 Raiko 服务（使用 Remote 模式）：

1. ✅ 配置了 PCCS 用于 SGX 远程证明
2. ✅ 设置了 devnet RPC 连接（127.0.0.1:8545）
3. ✅ 使用真实的 SGX 硬件和远程 SGX Prover（Remote 模式）
4. ✅ 完成了 SGX 实例的 Bootstrap
5. ✅ 启动了 SGX Server 和 Raiko Host 服务
6. ✅ 验证了所有服务的正常运行

**Remote 模式架构**：
- **Raiko Host** (端口 8080)：接收 HTTP 请求，处理证明逻辑
- **SGX Server** (端口 9090)：在 SGX Enclave 中执行证明生成
- 两个服务通过 HTTP API 通信，实现服务分离和资源隔离

现在可以通过 HTTP API 向 Raiko Host 发送证明请求，请求会被转发到 SGX Server 进行实际的证明生成。

