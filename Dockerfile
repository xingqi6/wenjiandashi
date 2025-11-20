FROM alpine:latest
WORKDIR /app

# 安装依赖
RUN apk add --no-cache curl tar ca-certificates libc6-compat coreutils

# 下载并执行更名伪装 (alist -> system-worker)
RUN curl -L https://github.com/alist-org/alist/releases/latest/download/alist-linux-musl-amd64.tar.gz -o temp.tar.gz \
    && tar -zxvf temp.tar.gz \
    && mv alist system-worker \
    && rm temp.tar.gz

# 复制脚本
COPY boot.sh .

# 权限设置 (适配 HF 用户 1000)
RUN mkdir -p data && chmod +x boot.sh system-worker && chown -R 1000:1000 /app

USER 1000
EXPOSE 7860
CMD ["./boot.sh"]
