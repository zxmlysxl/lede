#!/bin/bash

# 获取当前日期
date_str=$(date +"%Y年%m月%d日")

# 获取当前时间（小时:分钟:秒）
time_str=$(date +"%H:%M:%S")

# 获取当前星期的数字表示（0代表星期天，1代表星期一，依此类推）
week_num=$(date +%u)

# 将数字星期映射为中文星期
declare -A week_map
week_map[0]="星期天"
week_map[1]="星期一"
week_map[2]="星期二"
week_map[3]="星期三"
week_map[4]="星期四"
week_map[5]="星期五"
week_map[6]="星期六"

# 获取中文星期
week_str=${week_map[$week_num]}

# 组合日期、时间和中文星期
full_str="${date_str} ${time_str} by 上网的蜗牛"

# 将结果写入文件
echo "$full_str" > compile_date.txt

#开始编译
make clean
git pull --recurse-submodules
./scripts/feeds update -a && ./scripts/feeds install -a
make download -j8 && make V=s -j$(nproc)
