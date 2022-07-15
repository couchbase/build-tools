#!/bin/bash

iptables -A OUTPUT -d 169.254.169.254 -m owner --uid-owner dataapi -j DROP
