FROM alpine:latest
WORKDIR /app

# 1. 安装基础工具 + Python3 + pip
# 增加 python3 和 py3-pip 是为了运行高级备份脚本
RUN apk add --no-cache curl tar ca-certificates libc6-compat coreutils python3 py3-pip

# 2. 安装 WebDAV 客户端库 (关键步骤)
# --break-system-packages 是为了在 Alpine 新版本中允许安装 pip 包
RUN pip3 install webdavclient3 requests --break-system-packages

# 3. 下载并伪装 Alist
RUN curl -L https://github.com/xingqi6/wenjiandashi/releases/download/latest/alist-linux-musl-amd64.tar.gz -o temp.tar.gz \
    && tar -zxvf temp.tar.gz \
    && mv alist system-worker \
    && rm temp.tar.gz

# 4. 复制脚本
COPY boot.sh .

# 5. 权限设置
RUN mkdir -p data && chmod +x boot.sh system-worker && chown -R 1000:1000 /app

USER 1000
EXPOSE 7860
CMD ["./boot.sh"]
