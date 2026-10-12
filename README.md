## 互動式 SSH 安全配置腳本 · 一鍵加固你的 VPS

金鑰登入管理 · 密碼登入開關 · Fail2Ban防護 · SSH 連接埠修改

[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/Platform-Linux-FCC624?logo=linux&logoColor=black)](#)
![GitHub Stars](https://img.shields.io/github/stars/z21100644/key.sh?style=flat-square)

</div>

---

## ✨ 功能

- 🔑 **金鑰登入管理** — GitHub 拉取 / VPS 生成 / URL 匯入 / 一鍵開關
- 🔒 **密碼登入開關** — 啟用或禁用 `PasswordAuthentication`
- 🛡️ **Fail2Ban防護** — 一鍵安裝 / 參數調整 / 指數遞增封禁 / 白名單 / 日誌
- 🔧 **SSH 連接埠修改** — 自動放行防火牆，同步 Fail2Ban 連接埠
- ⚠️ **防鎖死保護** — 危險操作前紅色警告 + 二次確認

---

## 🐧 支援的系統

Debian · Ubuntu · RHEL · CentOS · Rocky · AlmaLinux · Fedora · Oracle · Amazon Linux · Alpine · Arch · Manjaro · openSUSE

自動偵測套件管理器、Init 系統、SSH 日誌路徑與防火牆。

---

## 🚀 快速開始

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/z21100644/key.sh/main/key.sh)
```

> 需要 root 權限或 sudo，首次執行自動安裝缺失依賴。

---

## 🖥️ 介面預覽

```
============================================================
                     SSH 安全配置工具
============================================================
 系統架構 : Debian 12
 金鑰登入 : 已啟用 (1 把公鑰)
 密碼登入 : 已禁用 (PasswordAuthentication no)
 Fail2Ban : 防護中 (已封禁0 IP)
 SSH 埠號 : 22
============================================================
 1. 金鑰登入管理
 2. 密碼登入開關
 3. Fail2Ban防護
 4. SSH 連接埠修改
 0. 退出腳本
============================================================
```

---


## ⌨️ 命令列模式

無需進入互動選單，可直接執行單次操作；多個參數可以組合，腳本會按固定順序執行。

### 常用命令

```bash
./key.sh -g <GitHub使用者>    # 從 GitHub 拉取公鑰
./key.sh -u <URL>             # 從自訂 URL 拉取公鑰
./key.sh -f <檔案>            # 從本地檔案匯入公鑰
./key.sh -p <連接埠>          # 修改 SSH 連接埠（自動同步防火牆與 Fail2Ban）
./key.sh -d                   # 禁用密碼登入
./key.sh -h                   # 顯示幫助
```

### 組合用法

```bash
# 一次性完成：拉取公鑰 → 改連接埠 → 禁用密碼登入
./key.sh -g <GitHub使用者> -p 2222 -d

# 覆蓋模式：先清空已存公鑰，再追加（-o 必須與 -g/-u/-f 配合）
./key.sh -o -g <GitHub使用者>
./key.sh -o -f /path/to/PublicKey.pub
```

### 參數說明

| 參數 | 說明 | 可單獨使用 |
|---|---|:---:|
| `-g <使用者>` | 從 GitHub 拉取公鑰 | ✅ |
| `-u <URL>` | 從自訂 URL 拉取公鑰 | ✅ |
| `-f <檔案>` | 從本地檔案匯入公鑰 | ✅ |
| `-p <連接埠>` | 修改 SSH 連接埠 | ✅ |
| `-d` | 禁用密碼登入 | ✅ |
| `-o` | 覆蓋模式，清空已存公鑰 | ❌ 需配合 `-g`/`-u`/`-f` |
| `-h` | 顯示幫助 | ✅ |



---

## 📖 使用示例

**新 VPS 初始化推薦流程：**

```
1. 執行腳本 → 1. 金鑰登入管理 → 選 1/2/3 新增公鑰
2. 【重要】新建終端，用金鑰登入測試
3. 測試成功後 → 2. 密碼登入開關 → 禁用密碼登入
4. 3. Fail2Ban防護 → 一鍵安裝
```

**修改連接埠：**

腳本會自動同步：`sshd_config` 更新 → 防火牆放行 → Fail2Ban 連接埠同步 → 重啟 SSH 服務。

> ⚠️ 記得在雲服務商安全組中放行新連接埠。

---

## ⚠️ 安全提示

- 禁用密碼登入前，請**先新建終端驗證金鑰登入成功**
- 危險操作會彈出紅色警告與二次確認，請仔細閱讀
- 建議把常用 IP 加入 Fail2Ban 白名單，避免誤封自己
- 腳本不收集任何資訊，所有操作均為本地執行

---



<div align="center">

如果這個腳本幫到了你，歡迎點一個 ⭐
