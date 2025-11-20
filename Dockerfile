FROM alpine:latest

# 1. 下载 -> 解压 -> 改名为 wenjiandashi -> 销毁证据
RUN apk add --no-cache curl tar && \
    curl -L https://github.com/xingqi6/wenjiandashi/releases/download/latest/alist-linux-musl-amd64.tar.gz -o core.tar.gz && \
    tar -zxvf core.tar.gz && \
    mv alist /usr/local/bin/wenjiandashi && \
    chmod +x /usr/local/bin/wenjiandashi && \
    rm core.tar.gz && \
    apk del curl tar

# 2. 设置默认入口
ENTRYPOINT [ "wenjiandashi" ]
