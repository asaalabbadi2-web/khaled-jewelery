FROM certbot/dns-cloudflare:v5.9.0
# The shop name's certificate (ADR-098): pinned -- v5.9.0 of 29 Oct 2026 --
# and run by its own loop, each attempt's status written for «صحة النظام».
COPY ops/certbot/pos_cert.py /opt/pos_cert.py
ENTRYPOINT ["python", "/opt/pos_cert.py"]
