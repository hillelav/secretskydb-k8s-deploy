# SecretSkyDB — End User License Agreement


Version 2.1

**Licensor:** SECRETSKYDB LTD, an Israeli company, HaEnergia St 77, Beersheba, Israel ("**SecretSkyDB**", "**we**")  
**Licensee:** The entity that installs, accesses, or uses the Software ("**you**")  
**Effective date:** On publication; replaces the agreement dated 19 August 2026 for versions of the Software released thereafter  
**Contact:** legal@secretskydb.com

By deploying, installing, or using the Software you agree to this Agreement. If you do not agree, do not install or use it. If you accept on behalf of an entity, you represent that you have authority to bind it. The Software is offered to businesses, public bodies, and other organizations for business use only; it is not offered to consumers.

## 1. Definitions

- "**Software**" — the SecretSkyDB proxy/reassembly engine, cache, orchestrator, custodian and reader components, deployer, Helm chart, container images, scripts, secret-sharing and related components, and any updates we make available, together with the Documentation.
- "**Documentation**" — the user, installation, and operational materials we provide for the Software.
- "**Marketplace**" — Google Cloud Marketplace or another distribution channel we authorize; "**Marketplace Provider**" — the operator of that Marketplace.
- "**Order Form**" — a written order, quote, private offer, or statement of work executed by both parties, or accepted through the Marketplace, that specifies the Subscription scope, fees, permitted deployments, and any additional terms.
- "**Authorized Partner**" — a reseller, integrator, or managed-service provider that we have authorized in writing to distribute, deploy, or operate the Software for its customers.
- "**Subscription**" — your entitlement to the Software for a period, obtained through the Marketplace or an Order Form, including a time-limited Evaluation.
- "**Evaluation**" — use of the Software without payment of fees, for the period stated in the Documentation or an Order Form, solely to assess it.
- "**Share Stores**" — the databases, storage services, or systems, in any location, that you select and operate to hold the shares the Software produces; "**Shares**" — the secret-shared fragments of your data produced by the Software.
- "**Customer Data**" — data you process with the Software, including Shares, indexes, and derived artifacts.
- "**SecretSkyDB Parties**" — SecretSkyDB and its affiliates, and their respective officers, directors, employees, contractors, and licensors.
- "**Confidential Information**" — as defined in Section 9.

## 2. License grant

Subject to your compliance with this Agreement and payment of applicable fees, we grant you a **limited, non-exclusive, non-transferable, non-sublicensable, revocable** license, during the term of your Subscription, to install and run the Software in the deployments, environments, and quantities for which fees are metered and paid through the Marketplace or that are stated in an Order Form, solely for your internal business purposes and solely to process your own data or data you are authorized to process on behalf of others. Software components designed to run in more than one location (for example Share Stores, custodians, or orchestrators in a second cloud or on your premises) may be deployed in each such location as part of the same licensed deployment. All rights not expressly granted are reserved.

**2.1 Authorized Partners.** An Authorized Partner may deploy, host, or operate the Software for its end customers solely under a separate written agreement with us; each end customer remains bound by this Agreement or by terms no less protective of us.

**2.2 Evaluation.** Evaluation use is licensed solely for assessment, for the Evaluation period, and ends automatically when that period expires. Evaluation deployments are provided without any support, warranty, or liability on our part beyond Section 11.

**2.3 Marketplace terms.** Your purchase through, and use of, the Marketplace, including billing, invoicing, refunds, credits, and the Marketplace Provider's own services and privacy practices, is governed solely by the Marketplace Provider's terms. This Agreement governs only the Software. We are not a party to, and have no liability under, the Marketplace Provider's terms; the Marketplace Provider is not a party to this Agreement, makes no commitment under it, and has no obligation to you in respect of the Software.

**2.4 Updates.** We may release updated versions of the Software. We have no obligation to maintain, support, or keep available any prior version. An updated version may be accompanied by an updated version of this Agreement, which applies to that version from the time you install or use it.

## 3. License restrictions

You shall **not**, and shall not permit any third party to:

1. **reverse engineer, decompile, disassemble, deobfuscate**, or otherwise attempt to derive the source code, algorithms, or structure of the Software, except to the limited extent this restriction is unenforceable under applicable mandatory law;
2. **copy, distribute, sublicense, resell, rent, lease, host as a service, or make the Software available** to any third party, except as expressly authorized in writing by us (including under Section 2.1), or as necessary for your contractors to operate the Software on your behalf under written confidentiality obligations;
3. **create derivative works** of, or incorporate the Software (in whole or part) into any other product or service;
4. remove, alter, or obscure any proprietary notices, labels, or marks;
5. use the Software to build a **competing product or service**, or to replicate the Software's implementation of its secret-sharing, reconstruction, or secure-computation components;
6. publish **benchmarks** or security-test results concerning the Software without our prior written consent (sharing results with your own regulators or auditors under confidentiality is permitted);
7. circumvent, disable, or falsify any license-key, entitlement, metering, usage-reporting, or attestation mechanism, or use the Software beyond your Subscription's scope;
8. use the Software in violation of applicable law or export/sanctions regulations, or to process data you have no right to process.

## 4. Ownership

The Software is **licensed, not sold**. We and our licensors retain all right, title, and interest in and to the Software, including all patents, copyrights, trade secrets, and other intellectual property. The Software embodies **valuable trade secrets and confidential information** of SecretSkyDB and is protected by patents and patent applications, as identified in the Documentation from time to time.

**4.1 Customer Data.** As between the parties, you own Customer Data, including all Shares. We claim no rights in it and do not receive it (Section 6).

**4.2 Feedback.** If you give us suggestions or feedback about the Software, we may use them without restriction or obligation to you.

## 5. Third-party components and services

The Software includes third-party and open-source components licensed under their own terms; a notices file listing them is included in the Documentation. Those terms govern those components; nothing in this Agreement restricts rights you have under an applicable open-source license as to those components.

The cloud services, databases, and other systems you use as Share Stores, caches, or hosting environments are selected, contracted, and operated by you under their providers' terms. We are not responsible for their availability, security, performance, data residency, or conduct, or for any loss resulting from them.

## 6. Fees and metering

Where applicable, fees are billed through the Marketplace or an Order Form and are non-refundable except as the Marketplace Provider's terms or an Order Form expressly provide. Where you obtain the Software through the Marketplace, the Software reports to the Marketplace Provider only the usage metrics required for billing (for example, proxy-hours), as described in the Documentation; it does not transmit Customer Data, Shares, queries, or content metadata to us or to any third party. Alternative licensing modes for air-gapped or restricted environments, if any, are specified in an Order Form. On our request, not more than once per year, you will confirm in writing that your use is within your Subscription's scope. Taxes are your responsibility, except taxes on our income.

## 7. Your responsibilities

You acknowledge that the Software protects data by splitting it into Shares held in Share Stores you control, and that its protection depends on how you deploy and operate it. You are solely responsible for:

1. **deployment and configuration**, including the choice, number, location, and independence of Share Stores, the reconstruction threshold, network exposure of the proxy, TLS, and all settings;
2. **availability of Shares and backups.** If fewer Share Stores than the reconstruction threshold are available, or Shares are lost, corrupted, or deleted, the corresponding data cannot be reconstructed by anyone, including us. You will maintain backups and recovery procedures appropriate to your data;
3. **credentials and access control**, including users, roles, passwords, keys, service accounts, and the systems from which the proxy is reached;
4. **your data and its lawful use**, including obtaining any consents and complying with privacy, data-residency, sectoral, and procurement rules that apply to you. We are not a processor or controller of Customer Data;
5. **validating** the Software's suitability for your purpose and regulatory environment before relying on it, and operating it according to the Documentation;
6. **not using the Software as the sole safeguard** in any application where failure could lead to death, personal injury, or severe physical or environmental damage. The Software is not designed or licensed for such use.

## 8. Term and termination

This Agreement runs for your Subscription term and ends automatically when your Subscription or Evaluation ends. We may **suspend or terminate** on notice if you materially breach this Agreement and fail to cure within 30 days, or immediately upon your breach of Sections 3, 4, or 9. We may also discontinue the Software or its availability on a Marketplace on reasonable notice; any refund or credit for a prepaid period is governed by the Marketplace Provider's terms or the applicable Order Form.

On termination you must **cease all use and delete all copies** of the Software. Your retention of Customer Data, including Shares, is unaffected; Shares remain in your Share Stores and we have no access to them. Any post-termination transition, continued use for export, or data-reconstruction assistance is provided only if and as stated in an Order Form. Sections 3, 4, 5, 7, 9, 10, 11, 12, 13, and 15 survive termination.

## 9. Confidentiality

The Software, its non-public components, and any technical or business information we disclose are our **Confidential Information**. You will protect it with at least reasonable care, use it only as permitted by this Agreement, and not disclose it except to employees and contractors with a need to know who are bound by confidentiality obligations no less protective than this Section. This Section supplements any separate NDA between the parties, which controls in the event of a conflict.

## 10. Warranty disclaimer

THE SOFTWARE IS PROVIDED **"AS IS"** AND **"AS AVAILABLE"**, WITHOUT WARRANTIES OF ANY KIND, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE, NON-INFRINGEMENT, AND ANY WARRANTY ARISING FROM COURSE OF DEALING OR USAGE OF TRADE. We do not warrant that the Software is error-free, uninterrupted, or secure, that it will meet your requirements, or that any data is unrecoverable by, or protected against, any particular adversary. No security product can guarantee that data will not be lost, intercepted, or disclosed. Features marked as beta, preview, or experimental are provided for testing only. Any warranty, support, or service-level commitment by us exists only if and as expressly stated in an Order Form.

## 11. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW: (a) NONE OF THE SECRETSKYDB PARTIES, AND NEITHER PARTY, IS LIABLE FOR INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR EXEMPLARY DAMAGES, OR FOR LOST PROFITS, LOST REVENUE, LOSS OF BUSINESS, LOSS OR CORRUPTION OF DATA, OR COSTS OF SUBSTITUTE SERVICES, HOWEVER ARISING AND EVEN IF ADVISED OF THEIR POSSIBILITY; (b) THE AGGREGATE LIABILITY OF THE SECRETSKYDB PARTIES, TAKEN TOGETHER, ARISING OUT OF OR RELATING TO THIS AGREEMENT OR THE SOFTWARE, UNDER ANY THEORY, SHALL NOT EXCEED THE FEES ACTUALLY RECEIVED BY US, DIRECTLY OR THROUGH THE MARKETPLACE PROVIDER, FOR YOUR USE OF THE SOFTWARE IN THE 12 MONTHS PRECEDING THE FIRST EVENT GIVING RISE TO THE CLAIM, OR, IF NO SUCH FEES WERE RECEIVED, USD 100. Multiple claims do not enlarge this limit. These limitations are an essential basis of the bargain, apply even if a remedy fails its essential purpose, and do not limit liability that cannot be limited by applicable law. Any higher cap, warranty, or indemnity by us exists only if and as stated in an Order Form.

## 12. Indemnification by you

You will defend, indemnify, and hold harmless the SecretSkyDB Parties from and against any third-party claim, including any claim by your users, customers, end customers, or affiliates, and resulting damages, costs, and reasonable legal fees, arising out of or relating to Customer Data, your deployment and configuration choices, your Share Stores, your use of the Software in breach of this Agreement, or your violation of applicable law.

## 13. Export control and compliance

You will comply with applicable export, sanctions, and anti-corruption laws. The Software is subject to Israeli export-control law and may be subject to the export laws of other jurisdictions. Certain deliveries may require authorization; you will provide end-user and end-use information we reasonably request, and will not export, re-export, or transfer the Software to any destination, end user, or end use where that would require an authorization we have not obtained, or that is subject to sanctions.

## 14. Data protection

The Software runs entirely within environments you control. We do not access, host, or process Customer Data in providing the Software, and we receive no personal data from the Software's operation. Any processing by us in connection with support services, if any, is governed by a data-processing agreement attached to an Order Form.

## 15. General

- **Governing law / venue:** this Agreement is governed by the laws of the State of Israel, excluding its conflict-of-laws rules; the competent courts of Tel Aviv have exclusive jurisdiction.
- **Injunctive relief:** breach of Sections 3, 4, or 9 may cause irreparable harm for which we may seek injunctive relief without posting bond.
- **Assignment:** you may not assign this Agreement without our consent; we may assign it to an affiliate or successor.
- **Entire agreement / order of precedence:** this Agreement, together with any Order Form and NDA, is the entire agreement between the parties about the Software and supersedes all prior proposals and understandings; an executed Order Form or NDA controls over conflicting terms of this Agreement. No terms in your purchase order or other document apply.
- **No third-party beneficiaries:** there are none, including the Marketplace Provider, except that the SecretSkyDB Parties may enforce Sections 11 and 12.
- **Force majeure:** neither party is liable for delay or failure caused by events beyond its reasonable control, other than payment obligations.
- **Notice and time limit for claims:** to the extent permitted by law, you must notify us in writing of any claim against us within 30 days after you become aware of the event giving rise to it, failing which the claim is waived, and in any event any claim against us must be brought within 12 months after that event.
- **Severability / waiver:** if any provision is unenforceable it will be enforced to the maximum extent permitted and the rest remains in effect; a waiver is effective only in writing.
- **Notices:** to us at legal@secretskydb.com; to you at the contact associated with your Subscription.
- **Language:** this Agreement is in English; any translation is for convenience only.
- **Government / defense customers:** additional terms apply only if and as stated in an Order Form.

**Contact:** legal@secretskydb.com  
© 2026 SecretSkyDB Ltd. All rights reserved.
