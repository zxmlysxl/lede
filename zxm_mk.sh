#!/bin/bash

set -e

# 初始备份（脚本启动立即执行）
backup_config() {
    local backup_dir="/home/zuoxm/backup/lede"
    local timestamp=$(date +"%Y%m%d")
    local backup_file="${backup_dir}/.config-${timestamp}"
    
    mkdir -p "$backup_dir"
    
    if [ -f .config ]; then
        if cp .config "$backup_file"; then
            echo -e "${GREEN}✓ 配置已备份: ${backup_file}${NC}"
        else
            echo -e "${RED}❌ 备份失败！请检查目录权限${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}⚠️ 未找到.config文件，跳过备份${NC}"
    fi
}

# 脚本起始处立即执行备份
backup_config

# 写入编译信息
echo "Z-Wrt $(date +"%Y%m%d%H%M") by zuoxm" > compile_date.txt

# 配置
LOG_FILE="build.log"          # 编译日志路径
MIN_FREE_SPACE_GB=10          # 降低磁盘空间要求
AUTO_PULL_TIMEOUT=3           # git pull 自动确认倒计时(秒)

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

# 内存优化的线程计算（8GB环境专用）
calc_jobs() {
    local total_cores=$(nproc --all)
    local available_mem=$(free -g | awk '/Mem:/ {print $7}')
    
    # 8GB内存限制规则：
    if [ $available_mem -lt 6 ]; then
        echo 2   # 内存不足时强制2线程
    else
        # 不超过4线程且至少保留1GB内存
        echo $(( total_cores > 4 ? 4 : 
                 total_cores > 1 ? total_cores - 1 : 1 ))
    fi
}

# 检查依赖工具
check_deps() {
    local missing=()
    for cmd in git make rsync wget; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}❌ 缺少依赖工具: ${missing[*]}${NC}"
        exit 1
    fi
}

# 检查磁盘空间
check_disk_space() {
    local free_space=$(df -BG . | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "$free_space" -lt "$MIN_FREE_SPACE_GB" ]; then
        echo -e "${RED}❌ 磁盘空间不足! 需要至少 ${MIN_FREE_SPACE_GB}G，当前剩余 ${free_space}G${NC}"
        exit 1
    fi
}

# 内存安全下载线程计算
calc_dl_threads() {
    echo $(( $(calc_jobs) > 4 ? 4 : $(calc_jobs) ))  # 下载不超过4线程
}

# 动态计时函数 (需安装pv)
dynamic_timer() {
    local msg="$1"
    local cmd="$2"
    
    # 时间格式化函数（内部使用）
    format_time() {
        local total_seconds=$1
        local minutes=$((total_seconds / 60))
        local seconds=$((total_seconds % 60))
        
        if (( minutes > 0 )); then
            printf "%d分%02d秒" "$minutes" "$seconds"
        else
            printf "%d秒" "$seconds"
        fi
    }

    echo -ne "${CYAN}▶ ${msg}...0秒${NC}"
    local start=$(date +%s)
    
    # 执行命令（后台运行）
    (eval "$cmd" &>> "$LOG_FILE") &
    local pid=$!
    
    # 动态计时循环
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$(( $(date +%s) - start ))
        echo -ne "\r${CYAN}▶ ${msg}...$(format_time $elapsed)${NC}"
        sleep 1
    done
    
    wait "$pid"  # 等待命令完成
    local elapsed=$(( $(date +%s) - start ))
    echo -e "\r${GREEN}✓ ${msg}完成 ($(format_time $elapsed))${NC} "
}

# 检查git更新（带倒计时自动确认）
check_git_updates() {
    git remote update &>/dev/null
    local local_commit=$(git rev-parse @)
    local remote_commit=$(git rev-parse @{u})

    if [ "$local_commit" != "$remote_commit" ]; then
        echo -e "${YELLOW}⚠️  发现远程仓库更新${NC}"
        
        # 倒计时自动确认
        for (( i=AUTO_PULL_TIMEOUT; i>0; i-- )); do
            printf "\r${CYAN}将在 %d 秒后自动更新 (按任意键取消)...${NC}" "$i"
            read -t 1 -n 1 -r && break
        done
        
        if [ $? -eq 0 ]; then
            echo
            read -p "确认更新? [Y/n] " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Nn]$ ]] && dynamic_timer "拉取代码" "git pull"
        else
            echo -e "\n${GREEN}▶ 自动执行更新...${NC}"
            dynamic_timer "拉取代码" "git pull"
        fi
    fi
}

# 公共编译流程
common_compile() {
    dynamic_timer "更新 feeds" "./scripts/feeds update -a"
    dynamic_timer "安装 feeds" "./scripts/feeds install -a"
    dynamic_timer "下载源码" "make download -j$DL_THREADS"
    
    local jobs=$(calc_jobs)
    echo -e "${CYAN}▶ 开始编译 (使用 $jobs 线程)...${NC}"
    echo -e "📝 日志实时输出到: ${YELLOW}$LOG_FILE${NC}"
    
    local compile_start=$(date +%s)
    if ! make -j$jobs V=s 2>&1 | tee -a "$LOG_FILE"; then
        echo -e "${RED}❌ 编译失败! (总耗时: $(($(date +%s)-compile_start))秒)${NC}"
        exit 1
    fi
    echo -e "${GREEN}✓ 编译成功! (总耗时: $(($(date +%s)-compile_start))秒)${NC}"
}

# 完整编译（内存优化版）
full_compile() {
    echo -e "\n${YELLOW}⚡ 执行内存安全完整编译...${NC}"
    check_git_updates
    
    echo -e "${YELLOW}♻️ 轻量级清理...${NC}"
    dynamic_timer "make clean" "make clean"  # 不执行dirclean节省内存
    
    common_compile
    echo -e "\n${GREEN}✅ 完整编译完成!${NC}"
    echo -e "${BLUE}ℹ️ 内存使用报告:${NC}"
    free -h
}

# 增量编译
quick_compile() {
    echo -e "\n${YELLOW}⚡ 执行增量编译 (跳过清理)...${NC}"
    check_git_updates
    common_compile
    echo -e "\n${GREEN}✅ 增量编译完成!${NC}"
}

# 交互式菜单
show_menu() {
    echo -e "\n${BLUE}OpenWrt编译助手 (8GB内存优化版)${NC}"
    echo "1) 完整编译"
    echo "2) 增量编译"
    echo "3) 退出"
    
    while true; do
        read -p "请选择: " choice
        case $choice in
            1) full_compile; break ;;
            2) quick_compile; break ;;
            3) exit 0 ;;
            *) echo -e "${RED}无效选项!${NC}" ;;
        esac
    done
}

# 初始化
check_deps
check_disk_space
show_menu
