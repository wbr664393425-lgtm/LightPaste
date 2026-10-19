import Foundation

/// Pure validation of ContentDetector, TextTransform and the link preview rules. Compile with Models.swift,
/// ContentDetector.swift, TextTransform.swift and Enrichment.swift (see README).
@main
struct VerifyDetection {
    static func main() {
        var failures = 0
        var passed = 0
        func check(_ label: String, _ condition: Bool) {
            if condition { passed += 1 } else { failures += 1; print("FAIL \(label)") }
        }
        func detail(_ text: String) -> ClipDetail? { ContentDetector.detect(kind: .text, text: text) }

        // Colors
        check("短十六进制颜色", detail("#0af") == .color)
        check("八位十六进制颜色", ContentDetector.color(in: "#FF000080")?.alpha == 128.0 / 255)
        check("rgb 颜色", ContentDetector.color(in: "rgb(255, 0, 0)") == .init(red: 1, green: 0, blue: 0, alpha: 1))
        check("rgba 颜色", detail("rgba(0,128,255,0.5)") == .color)
        check("hsl 颜色", ContentDetector.color(in: "hsl(120, 100%, 50%)").map { abs($0.green - 1) < 0.001 && $0.red < 0.001 } == true)
        check("越界 rgb 不算颜色", ContentDetector.color(in: "rgb(300, 0, 0)") == nil)
        check("话题标签不算颜色", detail("#周末") == nil)

        // Code
        check("Swift 代码", ContentDetector.codeLanguage("func load() {\n    let value = 1\n    return value\n}") == "Swift")
        check("JSON", ContentDetector.codeLanguage(#"{"name": "轻贴", "count": 3}"#) == "JSON")
        check("SQL", ContentDetector.codeLanguage("SELECT id, title FROM clips\nWHERE kind = 'text';") == "SQL")
        check("Python", ContentDetector.codeLanguage("def main():\n    print(\"hi\")\n    return 0") == "Python")
        check("中文段落不是代码", detail("今天下午三点开会（地点：三楼会议室），请准时参加；带上电脑。") == nil)
        check("英文句子不是代码", detail("Please review the attached document before the meeting tomorrow.") == nil)

        // Contact
        check("邮箱", detail("hello.world@example.com") == .email)
        check("中国手机号", detail("138 0013 8000") == .phone)
        check("带区号手机号", detail("+86 13800138000") == .phone)
        check("国际号码", detail("+1 415 555 0100") == .phone)
        check("普通数字不是电话", detail("20261019") == nil)

        // OTP
        check("中文验证码", ContentDetector.otp(in: "【轻贴】您的验证码是 482913，5 分钟内有效。") == "482913")
        check("英文验证码", detail("Your verification code is 7731") == .otp)
        check("无关键词数字不是验证码", ContentDetector.otp(in: "订单 482913 已发货") == nil)
        check("长文不判验证码", ContentDetector.otp(in: String(repeating: "验证码 1234 ", count: 40)) == nil)

        // Secrets
        check("OpenAI 风格密钥", detail("sk-proj-abcdefghijklmnopqrstuvwxyz012345") == .sensitive)
        check("GitHub 令牌", detail("ghp_" + String(repeating: "a1B2", count: 9)) == .sensitive)
        check("AWS 访问键", detail("AKIAIOSFODNN7EXAMPLE") == .sensitive)
        check("私钥", detail("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk=\n-----END OPENSSH PRIVATE KEY-----") == .sensitive)
        check("JWT", detail("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U") == .sensitive)
        check("测试卡号 4111", detail("4111 1111 1111 1111") == .sensitive)
        check("Luhn 无效卡号不算", ContentDetector.isBankCard("4111 1111 1111 1112") == false)
        check("身份证校验位正确", ContentDetector.isChineseID("11010519491231002X"))
        check("身份证在句中", detail("身份证号：11010519491231002X，请核对") == .sensitive)
        check("身份证校验位错误", ContentDetector.isChineseID("110105194912310021") == false)
        check("图片、文件类型不识别", ContentDetector.detect(kind: .image, text: "sk-proj-abcdefghijklmnopqrstuvwxyz012345") == nil
              && ContentDetector.detect(kind: .files, text: "/tmp/sk-proj-abcdefghijklmnopqrstuvwxyz012345") == nil)

        // Secrets anywhere in the text, and in links
        let secret = "sk-" + String(repeating: "A", count: 32)
        check("长文本末尾的密钥", detail(String(repeating: "a", count: 8_000) + "\n" + secret) == .sensitive)
        check("超长文本末尾的密钥", ContentDetector.isSensitive(String(repeating: "日志 ", count: 70_000) + secret))
        check("带 token 的链接是敏感内容", ContentDetector.detect(kind: .link, text: "https://example.invalid/reset?token=" + secret) == .sensitive)
        check("普通链接不是敏感内容", ContentDetector.detect(kind: .link, text: "https://example.com/docs?page=2") == nil)
        check("链接不做其他识别", ContentDetector.detect(kind: .link, text: "https://example.com/#0af") == nil)
        check("长文本中的普通数字不是银行卡", !ContentDetector.isBankCard(String(repeating: "4111111111111111 ", count: 10)))

        // Link previews
        func auto(_ string: String) -> Bool { URL(string: string).map(LinkPreviewService.allowsAutomaticFetch) ?? false }
        check("普通 HTTPS 自动预览", auto("https://www.apple.com.cn/mac/"))
        check("HTTP 不自动预览", !auto("http://example.com/"))
        check("本机地址不自动预览", !auto("https://localhost:8443/") && !auto("https://127.0.0.1/") && !auto("https://[::1]/"))
        check("私网地址不自动预览", !auto("https://10.1.2.3/") && !auto("https://172.20.0.5/") && !auto("https://192.168.1.1/")
              && !auto("https://169.254.1.1/") && !auto("https://100.64.0.1/") && !auto("https://[fd00::1]/"))
        check("公网 172.32 仍可预览", auto("https://172.32.0.1/"))
        check("内网域名不自动预览", !auto("https://wiki/") && !auto("https://nas.local/") && !auto("https://git.corp/")
              && !auto("https://router.home.arpa/"))
        check("带账号密码不自动预览", !auto("https://user:pass@example.com/"))
        check("带凭据参数不自动预览", !auto("https://example.com/reset?token=abc") && !auto("https://example.com/cb?code=abc")
              && !auto("https://s3.example.com/f?X-Amz-Signature=abc") && !auto("https://example.com/?api_key=1")
              && !auto("https://example.com/?resetToken=1"))
        check("普通参数可预览", auto("https://example.com/search?q=轻贴&page=2"))

        // Paste-as conversions
        check("去掉多余空白", TextTransform.trimmed.apply("  第一行   \n\n\n\n第二行\t\n  ") == "第一行\n\n第二行")
        check("合并为一行（中文不加空格）", TextTransform.singleLine.apply("今天\n  开会\nat 3pm\n") == "今天开会 at 3pm")
        check("JSON 格式化", TextTransform.jsonPretty.apply(#"{"b":1,"a":[1,2]}"#) == "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1\n}")
        check("JSON 压缩", TextTransform.jsonCompact.apply("{\n  \"a\": \"x/y\"\n}") == #"{"a":"x/y"}"#)
        check("非 JSON 不格式化", TextTransform.jsonPretty.apply("{不是 JSON}") == nil)
        check("去掉跟踪参数", TextTransform.cleanLinks.apply("看这个 https://example.com/a?id=7&utm_source=wx&fbclid=1#top 吧")
              == "看这个 https://example.com/a?id=7#top 吧")
        check("只有跟踪参数时去掉问号", TextTransform.cleanLinks.apply("https://example.com/a?utm_medium=x") == "https://example.com/a")
        check("HEX 转 RGB", TextTransform.rgb.apply("#FF8000") == "rgb(255, 128, 0)")
        check("RGB 转 HEX", TextTransform.hex.apply("rgb(255, 128, 0)") == "#FF8000")
        check("半透明转 HEX", TextTransform.hex.apply("rgba(0, 0, 0, 0.5)") == "#00000080")
        check("HEX 转 HSL", TextTransform.hsl.apply("#00FF00") == "hsl(120, 100%, 50%)")
        let offered = TextTransform.available(for: #"{"a":1}"#)
        check("JSON 提供格式化，不提供颜色", offered.contains(.jsonPretty) && !offered.contains(.hex))
        check("已整洁的单行中文只提供必要选项", TextTransform.available(for: "会议纪要").isEmpty)
        check("颜色提供其他格式", Set(TextTransform.available(for: "#336699")).isSuperset(of: [.rgb, .hsl]))

        // Snippet variables
        let fixed = Date(timeIntervalSince1970: 1_760_000_000)
        let expanded = SnippetExpander.expand("你好{光标}，今天是{日期}。{剪贴板}", now: fixed, clipboard: "附件")
        check("片段变量展开", expanded.text.hasPrefix("你好，今天是20") && expanded.text.hasSuffix("。附件"))
        check("光标位置", expanded.cursorFromEnd == expanded.text.count - 2)
        check("无变量不展开", !SnippetExpander.hasVariables("普通文本 {name}"))

        if failures > 0 {
            print("识别验证失败：\(failures) 项。")
            exit(1)
        }
        print("内容识别验证通过：\(passed) 项。")
    }
}
