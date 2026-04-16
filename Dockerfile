FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Kolkata

RUN apt-get update && apt-get install -y \
    sudo curl git wget nano tzdata lsof dos2unix file pkg-config \
    software-properties-common \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /root

COPY frappe_setup.sh /frappe_setup.sh
COPY entrypoint.sh   /entrypoint.sh

RUN dos2unix /frappe_setup.sh /entrypoint.sh \
    && chmod +x /frappe_setup.sh /entrypoint.sh

# 8000 = Frappe web UI
# 9000 = Socket.io
EXPOSE 8000
EXPOSE 9000

CMD ["/entrypoint.sh"]