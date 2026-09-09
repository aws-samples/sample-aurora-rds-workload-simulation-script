# Workload Simulation Scripts for Amazon RDS and Amazon Aurora

Scripts to simulate common workload patterns against Amazon RDS and Amazon Aurora databases, so you can observe and troubleshoot database behavior (e.g. with Amazon CloudWatch Database Insights) rather than guess at it.

> **⚠️ Sample code — not for production.** This repository (including all CloudFormation templates and workload scripts) is a **sample meant to demonstrate the concept of database workload/lock contention**, not a hardened reference architecture or a production deployment artifact. Before adapting any part of it for production use, review the security considerations documented in each subdirectory's README (e.g. [`PostgreSQL/README.md` Section 3.8](PostgreSQL/README.md#38-security-considerations)) and add the additional hardening it describes.

## PostgreSQL

The [`PostgreSQL/`](PostgreSQL/) directory contains a full walkthrough for simulating an order-placement workload against Amazon RDS PostgreSQL or Amazon Aurora PostgreSQL, including:

- An e-commerce schema and data generator
- Workload scripts for average, sporadic, and contentious (flash-sale-style) traffic
- A demonstration of how row lock contention degrades throughput, and how "striping" hot inventory rows resolves it

See [`PostgreSQL/README.md`](PostgreSQL/README.md) for setup instructions and a full walkthrough.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.