# OpenWrt QoS with HFSC

A Quality of Service (QoS) system for OpenWrt routers using the HFSC (Hierarchical Fair Service Curve) algorithm.

## About This Project

This project was developed as part of a Bachelor's thesis in Computer Science at the [University of Padova]([https://www.linkedin.com/school/university-of-padova/](https://www.linkedin.com/school/university-of-padova)), supervised by [Prof. Stefano Tomasin]([https://www.linkedin.com/in/stefano-tomasin/](https://www.linkedin.com/in/stefano-tomasin-6a92532/)).

**Thesis Title:** "Routing di Traffico con Diverso QoS in OpenWrt"  
**Academic Year:** 2024-2025

## What Does It Do?

This system helps manage network traffic on OpenWrt routers by:
- Prioritizing important traffic (VoIP, video calls, SSH)
- Allocating bandwidth fairly between users
- Reducing latency for real-time applications
- Controlling network congestion

## Installation

1. **Copy files to your OpenWrt router:**
```bash
scp qos.sh root@192.168.1.1:/usr/sbin/
scp qos.conf root@192.168.1.1:/etc/
scp qos root@192.168.1.1:/etc/init.d/
```

2. **Set permissions:**
```bash
ssh root@192.168.1.1
chmod +x /usr/sbin/qos.sh
chmod +x /etc/init.d/qos
```

3. **Enable the service:**
```bash
/etc/init.d/qos enable
```

## Configuration

Edit `/etc/qos.conf` to match your network:

**Basic settings:**
```bash
# Your network interfaces
IFACE_WAN="eth1"          # Internet connection
IFACE_LAN="eth0"          # Local network

# Your bandwidth (in kbit/s)
BANDA_UPLOAD=1000         # Upload speed
BANDA_DOWNLOAD=10000      # Download speed
```

**User priorities:**
```bash
# High priority users (Network addresses)
RETE_PRIORITA_ALTA="192.168.1.10/32 192.168.2.0/24"

# Medium priority users
RETE_PRIORITA_MEDIA="192.168.1.20/32"

# Low priority users
RETE_PRIORITA_BASSA="192.168.1.30/32"
```

**Bandwidth allocation:**
```bash
PCT_ALTA=50      # 50% for high priority
PCT_MEDIA=30     # 30% for medium priority
PCT_BASSA=15     # 15% for low priority
PCT_DEFAULT=5    # 5% for unclassified traffic
```

## Usage

**Start QoS:**
```bash
/etc/init.d/qos start
```

**Stop QoS:**
```bash
/etc/init.d/qos stop
```

**Restart QoS:**
```bash
/etc/init.d/qos restart
```

**View statistics:**
```bash
/usr/sbin/qos.sh status
```

**Monitor in real-time:**
```bash
/usr/sbin/qos.sh monitor
```

## Requirements

- OpenWrt router
- Required packages: `tc`, `iptables`, `ip`
- Kernel modules: `sch_hfsc`, `sch_sfq`, `cls_fw`

## License

This project was developed for academic purposes as part of a Bachelor's thesis at the University of Padova.

## Author

**Alberto Bettini**  
University of Padova - Department of Information Engineering

---

*For more details, please refer to the full thesis document.*
