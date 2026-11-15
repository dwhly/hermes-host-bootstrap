# A stand-in company node / drill host for the fleet-company-db prototype: stock Ubuntu 24.04 with
# systemd as PID 1, so the real module, units and timers run exactly as on h-af / h-btp.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates python3 sudo procps iproute2 curl \
    && rm -f /etc/systemd/system/*.wants/* /lib/systemd/system/multi-user.target.wants/getty* \
    && systemctl mask systemd-logind.service getty.target console-getty.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
