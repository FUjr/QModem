#!/usr/bin/env python3
"""
UBUS 并发压测脚本 —— AT 命令批量发送与响应验证
=====================================================

主要用途
--------
1. 适配新模块：批量发送常用 AT 命令，快速确认模块基本功能正常。
2. 故障排查：并发压测指定命令，定位模块或 at-daemon 在高负载下的异常响应。

快速配置
--------
- IP          : 修改脚本顶部 `IP` 变量，填入 OpenWrt 设备的 IP 地址。
                示例：IP = "192.168.8.1"

- AT_PORT     : 修改 `AT_PORT`，填入模块对应的 AT 串口设备路径。
                示例：AT_PORT = "/dev/ttyUSB2"
                提示：可在设备上运行 `ls /dev/ttyUSB*` 或查看 qmodem 识别结果确认端口。

- AT_COMMANDS : 修改 `AT_COMMANDS` 列表，填入需要测试的 AT 命令。
                测试新模块时建议包含高级命令，如锁频查询、邻区搜索、网络状态等
                例：AT_COMMANDS = ["ATI", "AT+CSQ", "AT+CREG?", "AT+CGSN"]

- NUM_CALL : 修改测试次数，默认 100。
- NUM_THREAD : 修改线程数，默认 10。
                排查串口锁或队列溢出问题时可适当调大（如 500~1000）。

- LOGIN_USERNAME / LOGIN_PASSWORD : OpenWrt 登录凭据，默认 root / 空密码。

输出说明
--------
- 成功率、响应时间分布、按命令分组的统计结果会打印到终端。
- 详细结果自动保存为 ubus_test_results_<timestamp>.json，便于离线分析。
"""

import json
import time
import requests
import random
from concurrent.futures import ThreadPoolExecutor, as_completed
from threading import Lock
from datetime import datetime
IP="10.117.152.1"
# 配置
OPENWRT_URL = f"http://{IP}/ubus"  # 修改为你的 OpenWrt 设备地址
UBUS_SERVICE = "at-daemon"
UBUS_METHOD = "sendat"
AT_PORT = "/dev/ttyUSB3"

# 登录凭据
LOGIN_USERNAME = "root"
LOGIN_PASSWORD = ""

# AT 命令列表
AT_COMMANDS = ["ATI", "AT+CSQ", "AT+CGSN", "AT+CGMI", "AT+CGMM"]
NUM_THREAD = 10
NUM_CALL = 100

# 用于线程安全的统计
stats_lock = Lock()
results = []
success_count = 0
failure_count = 0


def get_rpc_token(username: str = LOGIN_USERNAME, password: str = LOGIN_PASSWORD) -> str:
    """
    通过 UBUS RPC 登录获取会话 token。

    Args:
        username: OpenWrt 用户名，默认从配置读取
        password: OpenWrt 密码，默认从配置读取

    Returns:
        str: 成功时返回 ubus_rpc_session token；失败时抛出异常
    """
    payload = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "call",
        "params": [
            "00000000000000000000000000000000",
            "session",
            "login",
            {"username": username, "password": password}
        ]
    }
    headers = {"Content-Type": "application/json"}

    response = requests.post(OPENWRT_URL, json=payload, headers=headers, timeout=10)
    response.raise_for_status()

    data = response.json()
    # 正常响应: {"result": [0, {"ubus_rpc_session": "<token>", ...}]}
    if "result" not in data or len(data["result"]) < 2:
        raise RuntimeError(f"登录响应格式异常: {data}")

    code, body = data["result"][0], data["result"][1]
    if code != 0:
        raise RuntimeError(f"登录失败，UBUS 错误码: {code}")

    token = body.get("ubus_rpc_session")
    if not token:
        raise RuntimeError(f"响应中未找到 ubus_rpc_session: {body}")

    return token


def make_ubus_call(thread_id, token: str = "00000000000000000000000000000000"):
    """
    执行单次 UBUS 调用
    
    Args:
        thread_id: 线程编号
        token: UBUS RPC 会话 token
        
    Returns:
        dict: 包含测试结果的字典
    """
    global success_count, failure_count
    
    # 随机选择一个 AT 命令
    at_cmd = random.choice(AT_COMMANDS)
    
    ubus_params = {
        "at_port": AT_PORT,
        "at_cmd": at_cmd
    }
    
    payload = {
        "jsonrpc": "2.0",
        "id": thread_id,
        "method": "call",
        "params": [token, UBUS_SERVICE, UBUS_METHOD, ubus_params]
    }
    
    headers = {
        "Content-Type": "application/json"
    }
    
    result = {
        "thread_ids": thread_id,
        "at_cmd": at_cmd,
        "start_time": None,
        "end_time": None,
        "duration_ms": None,
        "status": "failure",
        "response": None,
        "response_time_ms": None,
        "error": None
    }
    
    try:
        result["start_time"] = time.time()
        response = requests.post(
            OPENWRT_URL,
            json=payload,
            headers=headers,
            timeout=30
        )
        result["end_time"] = time.time()
        result["duration_ms"] = (result["end_time"] - result["start_time"]) * 1000
        
        if response.status_code == 200:
            data = response.json()

            # JSON-RPC 层错误（如 -32002 Access denied）
            if "error" in data:
                rpc_err = data["error"]
                code = rpc_err.get("code", "?")
                msg = rpc_err.get("message", "unknown")
                result["error"] = f"RPC error {code}: {msg}"
                with stats_lock:
                    failure_count += 1

            # 检查 UBUS 调用是否成功
            elif "result" in data and len(data["result"]) >= 2:
                ubus_result = data["result"][1]
                
                if ubus_result.get("status") == "success":
                    result["status"] = "success"
                    result["response"] = ubus_result.get("response", "")
                    result["response_time_ms"] = ubus_result.get("response_time_ms", 0)
                    
                    with stats_lock:
                        success_count += 1
                else:
                    result["error"] = f"UBUS call failed: {ubus_result.get('status')}"
                    with stats_lock:
                        failure_count += 1
            else:
                result["error"] = f"Unexpected response format: {data}"
                with stats_lock:
                    failure_count += 1
        else:
            result["error"] = f"HTTP error: {response.status_code}"
            with stats_lock:
                failure_count += 1
                
    except requests.exceptions.Timeout:
        result["error"] = "Request timeout"
        with stats_lock:
            failure_count += 1
    except requests.exceptions.RequestException as e:
        result["error"] = f"Request exception: {str(e)}"
        with stats_lock:
            failure_count += 1
    except Exception as e:
        result["error"] = f"Unexpected error: {str(e)}"
        with stats_lock:
            failure_count += 1
    
    return result


def main():
    """主函数：执行并发测试"""
    print("=" * 80)
    print("UBUS 并发测试")
    print("=" * 80)
    print(f"目标地址: {OPENWRT_URL}")
    print(f"服务: {UBUS_SERVICE}")
    print(f"方法: {UBUS_METHOD}")
    print(f"AT 端口: {AT_PORT}")
    print(f"AT 命令列表: {', '.join(AT_COMMANDS)}")
    print(f"并发线程数: {NUM_CALL}")
    print(f"线程组数: {NUM_CALL // NUM_THREAD + (1 if NUM_CALL % NUM_THREAD else 0)}")
    print("=" * 80)
    print()

    # 登录获取 RPC token
    print(f"正在登录 {OPENWRT_URL} (用户: {LOGIN_USERNAME}) ...")
    try:
        rpc_token = get_rpc_token()
        print(f"登录成功，token: {rpc_token[:8]}...{rpc_token[-4:]}\n")
    except Exception as e:
        print(f"登录失败: {e}")
        return

    # 开始测试
    start_time = time.time()
    print(f"开始时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}")
    print(f"启动 {NUM_THREAD} 个并发线程 发起 {NUM_CALL}次请求...\n")
    
    # 使用线程池执行并发请求
    with ThreadPoolExecutor(max_workers=NUM_THREAD) as executor:
        # 提交所有任务
        futures = {executor.submit(make_ubus_call, i, rpc_token): i for i in range(1, NUM_CALL + 1)}
        
        # 等待所有任务完成并收集结果
        for future in as_completed(futures):
            result = future.result()
            results.append(result)
            
            # 显示进度
            completed = len(results)
            if completed % NUM_THREAD == 0 or completed == NUM_CALL:
                print(f"进度: {completed}/{NUM_CALL} 完成")
    
    end_time = time.time()
    total_duration = end_time - start_time
    
    print()
    print("=" * 80)
    print("测试完成！")
    print("=" * 80)
    print(f"结束时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}")
    print(f"总耗时: {total_duration:.3f} 秒")
    print()
    
    # 统计结果
    print("=" * 80)
    print("统计结果")
    print("=" * 80)
    print(f"请求统计: 成功 {success_count} / 失败 {failure_count} / 总数 {NUM_CALL} (成功率: {(success_count / NUM_CALL * 100):.2f}%)")
    print()
    
    # 计算成功请求的响应时间统计
    if success_count > 0:
        successful_results = [r for r in results if r["status"] == "success"]
        response_times = [r["response_time_ms"] for r in successful_results]
        request_durations = [r["duration_ms"] for r in successful_results]
        
        print(f"AT 响应时间 (ms): 最小 {min(response_times)} / 最大 {max(response_times)} / 平均 {sum(response_times) / len(response_times):.2f}")
        print(f"HTTP 请求耗时 (ms): 最小 {min(request_durations):.2f} / 最大 {max(request_durations):.2f} / 平均 {sum(request_durations) / len(request_durations):.2f}")
        print()
    
    # 统计响应内容分组
    print("=" * 80)
    print("响应内容统计（按内容分组）")
    print("=" * 80)
    
    # 对成功的响应按 AT 命令和内容分组
    response_groups = {}
    for result in results:
        if result["status"] == "success":
            at_cmd = result.get("at_cmd", "unknown")
            response_content = result["response"]
            group_key = f"{at_cmd}||{response_content}"
            
            if group_key not in response_groups:
                response_groups[group_key] = {
                    "at_cmd": at_cmd,
                    "response": response_content,
                    "count": 0,
                    "thread_ids": [],
                    "response_times": []
                }
            response_groups[group_key]["count"] += 1
            response_groups[group_key]["thread_ids"].append(result["thread_id"])
            response_groups[group_key]["response_times"].append(result["response_time_ms"])
    
    # 打印分组统计
    group_num = 1
    for group_key, group_info in sorted(response_groups.items()):
        print(f"\n[组 #{group_num}] AT命令: {group_info['at_cmd']} | 次数: {group_info['count']}")
        
        # 计算该组的响应时间统计
        times = group_info['response_times']
        print(f"  响应时间(ms): 最小 {min(times)} / 最大 {max(times)} / 平均 {sum(times) / len(times):.2f}")
        
        thread_ids_str = ', '.join(map(str, group_info['thread_ids'][:10]))
        if group_info['count'] > 10:
            thread_ids_str += f" ... (共{group_info['count']}个线程)"
        print(f"  线程: {thread_ids_str}")
        
        # 格式化显示响应内容 - 单行显示
        response_content = group_info['response'].replace('\r\n', ' ').replace('\n', ' ').strip()
        # 限制长度避免过长
        if len(response_content) > 150:
            response_content = response_content[:150] + "..."
        print(f"  响应: {response_content}")
        
        group_num += 1
    
    # 统计失败的情况
    if failure_count > 0:
        print(f"\n失败情况统计:")
        error_groups = {}
        for result in results:
            if result["status"] == "failure":
                error_msg = result["error"]
                if error_msg not in error_groups:
                    error_groups[error_msg] = {
                        "count": 0,
                        "thread_ids": []
                    }
                error_groups[error_msg]["count"] += 1
                error_groups[error_msg]["thread_ids"].append(result["thread_id"])
        
        for error_msg, error_info in error_groups.items():
            thread_ids_str = ', '.join(map(str, error_info['thread_ids'][:10]))
            if error_info['count'] > 10:
                thread_ids_str += f" ... (共{error_info['count']}个)"
            print(f"  [{error_msg}] 次数: {error_info['count']} | 线程: {thread_ids_str}")
    
    
    # 统计每个 AT 命令的使用情况
    print("\n" + "=" * 80)
    print("AT 命令分布统计")
    print("=" * 80)
    at_cmd_stats = {}
    for result in results:
        cmd = result.get("at_cmd", "unknown")
        if cmd not in at_cmd_stats:
            at_cmd_stats[cmd] = {
                "count": 0,
                "success": 0,
                "failure": 0,
                "response_times": []
            }
        at_cmd_stats[cmd]["count"] += 1
        if result["status"] == "success":
            at_cmd_stats[cmd]["success"] += 1
            at_cmd_stats[cmd]["response_times"].append(result["response_time_ms"])
        else:
            at_cmd_stats[cmd]["failure"] += 1
    
    for cmd, stats in sorted(at_cmd_stats.items()):
        success_rate = (stats['success'] / stats['count'] * 100) if stats['count'] > 0 else 0
        print(f"{cmd}: 成功 {stats['success']} / 失败 {stats['failure']} / 总数 {stats['count']} (成功率: {success_rate:.2f}%)", end="")
        if stats['response_times']:
            avg_time = sum(stats['response_times']) / len(stats['response_times'])
            print(f" | 响应时间(ms): 最小 {min(stats['response_times'])} / 最大 {max(stats['response_times'])} / 平均 {avg_time:.2f}")
        else:
            print()
    
    print()
    print("=" * 80)
    
    # 保存结果到 JSON 文件
    output_file = f"ubus_test_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump({
            "test_config": {
                "url": OPENWRT_URL,
                "service": UBUS_SERVICE,
                "method": UBUS_METHOD,
                "at_port": AT_PORT,
                "at_commands": AT_COMMANDS,
                "NUM_CALL": NUM_CALL
            },
            "summary": {
                "total_requests": NUM_CALL,
                "success_count": success_count,
                "failure_count": failure_count,
                "success_rate": success_count / NUM_CALL * 100,
                "total_duration_seconds": total_duration,
                "at_cmd_stats": at_cmd_stats
            },
            "results": results
        }, f, ensure_ascii=False, indent=2)
    
    print(f"详细结果已保存到: {output_file}")
    print()


if __name__ == "__main__":
    main()
