# 使用最新的 Alpine Linux 作为基础，体积小，混淆性强
FROM alpine:latest

# 设置标签（可选，看起来更正规）
LABEL maintainer="security_admin"

# 1. 安装基础依赖 (curl用于下载，ca-certificates用于https，tar用于解压)
RUN apk add --no-cache curl ca-certificates tar bash

# 2. 核心步骤：下载 -> 解压 -> 重命名 -> 清理
# 这里我们直接下载 musl 版本，体积最小且兼容性最好
RUN curl -L https://github.com/xingqi6/wenjiandashi/releases/download/latest/alist-linux-musl-amd64.tar.gz -o alist.tar.gz && \
    tar -zxvf alist.tar.gz && \
    # ！！！关键混淆步骤！！！
    # 将 alist 重命名为 wenjiandashi (或者你想要的任何混淆名称)
    mv alist /usr/local/bin/wenjiandashi && \
    # 赋予执行权限
    chmod +x /usr/local/bin/wenjiandashi && \
    # 删除压缩包，毁尸灭迹
    rm alist.tar.gz

# 3. 创建一个挂载点目录（为了兼容性）
WORKDIR /opt/data

# 4. 默认命令（虽然HF部署时会覆盖这个，但保留一个默认值是个好习惯）
# 当你运行这个镜像时，它看起来就像是一个叫 wenjiandashi 的系统服务
ENTRYPOINT [ "wenjiandashi" ]
CMD [ "server", "--no-prefix" ]
