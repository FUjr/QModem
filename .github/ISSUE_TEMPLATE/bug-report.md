---
name: Bug Report
about: Create a report to help us improve
title: "[BUG]"
labels: bug
assignees: ''

---

**描述问题**  
提供模组型号、路由器平台、路由器系统发行版等信息  
**Describe the Issue**  
Provide module model, router platform, router system distribution, etc.

---

**复现方法**  
**Steps to Reproduce**  
1. Go to '...'  
2. Click on '...'  
3. Scroll down to '...'  
4. See the error

---

**期望行为**  
描述正常情况下应该是什么行为  
**Expected Behavior**  
Describe what the normal behavior should be.

---

**屏幕截图**  
**Screenshots**  

---

**日志信息**  
请在终端执行以下命令并将结果粘贴到对应的折叠代码块中  
**Log Information**  
Please execute the following commands in the terminal and paste the results into the corresponding collapsible code blocks below:

<details>
<summary>模组配置 (Module Configuration)</summary>

```bash
uci show qmodem
# 显示模组配置
# Show module configuration
```

粘贴结果到此处  
Paste the output here
```
```
</details>

<details>
<summary>网络配置 (Network Configuration)</summary>

```bash
uci show network
# 显示网络配置
# Show network configuration
```

粘贴结果到此处  
Paste the output here
```
```
</details>

<details>
<summary>系统日志 (System Logs)</summary>

```bash
logread
# 查看系统日志
# View system logs
```

粘贴结果到此处  
Paste the output here
```
```
</details>

<details>
<summary>内核日志 (Kernel Logs)</summary>

```bash
dmesg
# 查看内核日志
# View kernel logs
```

粘贴结果到此处  
Paste the output here
```
```
</details>

如果是USB模组相关的问题，执行以下命令并填写结果：  
**If the issue is related to USB modules, execute the following command and paste the output:**

<details>
<summary>USB设备信息 (USB Devices)</summary>

```bash
lsusb
# 列出USB设备
# List USB devices
```

粘贴结果到此处  
Paste the output here
```
```
</details>

如果是PCIe模组相关的问题，执行以下命令并填写结果：  
**If the issue is related to PCIe modules, execute the following command and paste the output:**

<details>
<summary>PCIe设备信息 (PCIe Devices)</summary>

```bash
lspci
# 列出PCIe设备
# List PCIe devices
```

粘贴结果到此处  
Paste the output here
```
```
</details>

如果模组扫描存在问题，执行以下命令并填写结果：  
**If there is an issue with module scanning, execute the following command and paste the output:**

<details>
<summary>模组扫描 (Module Scanning)</summary>

```bash
/usr/share/qmodem/modem_scan.sh scan
# 扫描模组
# Scan modules
```

粘贴结果到此处  
Paste the output here
```
```
</details>
