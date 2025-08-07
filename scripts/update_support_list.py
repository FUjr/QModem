import json
import sys




def generate_markdown(result):
# 生成 Markdown 格式
    markdown_output = []
    for vendor, models in result.items():
        markdown_output.append(f"# {vendor}")
        markdown_output.append("Model | Platform | USB  | PCIe ")
        markdown_output.append("--- | --- | --- | ---")
        for model, support in models.items():
            markdown_output.append(f"{model} | {support['platform']} |{support['usb']} | {support['pcie']}")
        markdown_output.append("")  # 空行分隔
    return markdown_output

def generate_github_release_notes(result):
    # 生成 GitHub 发布说明格式
    release_notes = []
    for vendor, models in result.items():
        release_notes.append(f"## {vendor}")
        for model, support in models.items():
            release_notes.append(f"- {model}: USB - {support['usb']}, PCIe - {support['pcie']}")
        release_notes.append("")
    return release_notes


if __name__ == "__main__":
    prefix = sys.argv[1] if len(sys.argv) > 1 else 'support_list'
    file_name = sys.argv[2] if len(sys.argv) > 2 else 'application/qmodem/files/usr/share/qmodem/modem_support.json'
    # 加载 JSON 数据
    with open(file_name, 'r') as file:
        data = json.load(file)

    # 初始化结果字典
    result = {}

    # 遍历 USB 和 PCIe 数据
    for interface_type in ['usb', 'pcie']:
        for model, details in data['modem_support'][interface_type].items():
            vendor = details.get('manufacturer', 'unknown').lower()
            platform = details.get('platform', 'unknown').lower()
            modes = ','.join(details.get('modes', []))
            support = f"✔ {interface_type}({modes})"
            
            if vendor not in result:
                result[vendor] = {}
            if model not in result[vendor]:
                result[vendor][model] = {'usb': '✘', 'pcie': '✘'}
            
            result[vendor][model][interface_type] = support
            result[vendor][model]['platform'] = platform
    markdown_output = generate_markdown(result)
    release_notes = generate_github_release_notes(result)
    with open(f"{prefix}.md", 'w') as f:
        f.write("\n".join(markdown_output))
    with open(f"{prefix}_release_notes.md", 'w') as f:
        f.write("\n".join(release_notes))
