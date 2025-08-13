#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# —— 1. 查询当前状态 —— #
cur_mode=$(adb shell settings get secure location_mode 2>/dev/null | tr -d '\r')
cur_assisted=$(adb shell settings get global assisted_gps_enabled 2>/dev/null | tr -d '\r')
cur_wifi=$(adb shell settings get global wifi_scan_always_enabled 2>/dev/null | tr -d '\r')
cur_ble=$(adb shell settings get global ble_scan_always_enabled 2>/dev/null | tr -d '\r')

case "$cur_mode" in
  0) mode_desc="定位已关闭" ;;
  1) mode_desc="仅使用 GPS" ;;
  2) mode_desc="仅网络定位" ;;
  3) mode_desc="高精度 (GPS+网络)" ;;
  *) mode_desc="未知模式" ;;
esac

echo "当前定位 & 辅助设置："
echo "  定位模式 (location_mode)          : $cur_mode ($mode_desc)"
echo "  辅助 GPS 定位 (assisted_gps_enabled): $cur_assisted"
echo "  Wi-Fi 扫描辅助 (wifi_scan_always_enabled): $cur_wifi"
echo "  蓝牙 扫描辅助 (ble_scan_always_enabled)  : $cur_ble"
echo

# —— 2. 自动判断操作并确认 —— #
# 判断当前是否为高精度模式且所有辅助都开启
if [[ "$cur_mode" == "3" && "$cur_assisted" == "1" && "$cur_wifi" == "1" && "$cur_ble" == "1" ]]; then
  # 当前是高精度+全辅助，建议切换到仅GPS
  operation="0"
  operation_desc="仅GPS+关闭所有辅助"
  new_mode=1
  new_desc="仅使用 GPS"
  new_assisted=0
  new_wifi=0
  new_ble=0
else
  # 其他情况，建议切换到高精度+全辅助
  operation="1"
  operation_desc="高精度+开启所有辅助"
  new_mode=3
  new_desc="高精度 (GPS+网络)"
  new_assisted=1
  new_wifi=1
  new_ble=1
fi

echo "🔍 根据当前状态，建议执行操作：$operation ($operation_desc)"
echo
read -n 1 -s -p "按任意键继续执行，或按 Ctrl+C 取消..."
echo
echo

echo
echo "🔧 正在通过 ADB 应用设置："
echo "  定位模式 → $new_mode ($new_desc)"
echo "  辅助 GPS 定位 → $new_assisted"
echo "  Wi-Fi 扫描辅助 → $new_wifi"
echo "  蓝牙 扫描辅助 → $new_ble"
echo

# —— 3. 写入新设置 —— #
adb shell settings put secure location_mode           "$new_mode"
adb shell settings put global assisted_gps_enabled    "$new_assisted"
adb shell settings put global wifi_scan_always_enabled "$new_wifi"
adb shell settings put global ble_scan_always_enabled  "$new_ble"

# —— 4. 再次查询并显示结果 —— #
final_mode=$(adb shell settings get secure location_mode | tr -d '\r')
final_assisted=$(adb shell settings get global assisted_gps_enabled | tr -d '\r')
final_wifi=$(adb shell settings get global wifi_scan_always_enabled | tr -d '\r')
final_ble=$(adb shell settings get global ble_scan_always_enabled | tr -d '\r')

case "$final_mode" in
  1) final_desc="仅使用 GPS" ;;
  3) final_desc="高精度 (GPS+网络)" ;;
  0) final_desc="定位已关闭" ;;
  2) final_desc="仅网络定位" ;;
  *) final_desc="未知模式" ;;
esac

echo "✅ 设置完成，当前状态："
echo "  定位模式          : $final_mode ($final_desc)"
echo "  辅助 GPS 定位     : $final_assisted"
echo "  Wi-Fi 扫描辅助   : $final_wifi"
echo "  蓝牙 扫描辅助     : $final_ble"
echo
echo "🎉 脚本执行完成！"
read -n 1 -s -p "按任意键退出..."
echo