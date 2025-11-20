FROM alpine:latest

# 1. 安装系统依赖
RUN apk add --no-cache python3 py3-pip curl tar gzip bash jq ca-certificates libc6-compat

# 2. 创建专用用户 (HF 强制要求非 root)
RUN adduser -D -u 1000 user

# 3. 准备目录
RUN mkdir -p /home/user/data && chown -R user:user /home/user

# 4. 设置环境变量
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH 

WORKDIR $HOME/app

# 5. 创建 Python 虚拟环境并安装依赖
ENV VIRTUAL_ENV=$HOME/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir requests webdavclient3 --break-system-packages

# 6. 下载 Alist 并伪装成 system-service
RUN curl -L https://github.com/alist-org/alist/releases/latest/download/alist-linux-musl-amd64.tar.gz -o alist.tar.gz \
    && tar -zxvf alist.tar.gz \
    && mv alist system-service \
    && rm alist.tar.gz \
    && chmod +x system-service

# 7. 复制脚本和配置
COPY --chown=user sync_data.sh $HOME/app/
COPY --chown=user config.json $HOME/app/data/config.json

# 8. 赋予权限
RUN chmod +x $HOME/app/sync_data.sh
RUN chown -R user:user /home/user

# 9. 切换用户
USER user

# 10. 暴露端口
EXPOSE 7860

# 11. 启动
CMD ["/bin/bash", "/home/user/app/sync_data.sh"]
