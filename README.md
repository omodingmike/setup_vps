# 🚀 SmartDuuka VPS Setup & Deployment Guide

This repository contains the automation scripts required to provision a brand-new Ubuntu/Debian Virtual Private Server (VPS) and deploy the SmartDuuka frontend and backend applications using Docker.

## ⚠️ Prerequisites
* A fresh, unmodified VPS running Ubuntu or Debian.
* `root` SSH access to the server.
* Your local SSH Public Key (you will be prompted to paste this during setup).

---

## Step 1: Initial Server Setup (Run as Root)
The first script secures the server, creates a dedicated deployment user, installs Docker, and hardens SSH access.

1. Log into your fresh server as `root`:
   ```bash
   ssh root@YOUR_SERVER_IP