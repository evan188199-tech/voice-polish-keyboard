import SwiftUI

struct KeyboardGuideView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        step(1, "打开「设置」App")
                        step(2, "点击「通用」→「键盘」→「键盘」")
                        step(3, "点击「添加新键盘」")
                        step(4, "在第三方键盘列表中选择「粤英语音键盘」")
                        step(5, "返回键盘列表，点击「粤英语音键盘」")
                        step(6, "开启「允许完全访问」开关")
                    }
                    .font(.subheadline)
                } header: {
                    Text("安装步骤")
                } footer: {
                    Text("开启完全访问后，键盘才能与本应用通信来控制语音输入。本应用不会记录或上传任何键盘输入内容。")
                }

                Section {
                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("键盘安装指引")
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
            Text(text)
        }
    }
}
