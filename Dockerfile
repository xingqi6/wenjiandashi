FROM alpine:latest
RUN apk add --no-cache python3 py3-pip curl tar gzip bash ca-certificates libc6-compat
RUN pip3 install requests webdavclient3 --break-system-packages
RUN adduser -D -u 1000 user
RUN mkdir -p /home/user/data && chown -R user:user /home/user
WORKDIR /home/user/app
RUN curl -L https://github.com/alist-org/alist/releases/latest/download/alist-linux-musl-amd64.tar.gz -o core.tar.gz \
    && tar -zxvf core.tar.gz \
    && mv alist sys-kernel \
    && rm core.tar.gz \
    && chmod +x sys-kernel
COPY --chown=user manager.py .
COPY --chown=user config.json ./data/config.json
RUN chown -R user:user /home/user/app
USER user
EXPOSE 7860
CMD ["python3", "-u", "manager.py"]
