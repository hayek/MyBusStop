# MOT SIRI-SM: assumptions checked against official sources (2026-09-17)

Sources read directly:
- Developer page (read in a real browser): https://www.gov.il/he/pages/real_time_information_siri (published 26.10.2020, updated 13.05.2025). Its attachments are only the **registration form** and the **ICD SM**.
- Form: https://www.gov.il/BlobFolder/generalpage/real_time_information_siri/he/real_time_information_receipt_form.pdf (sha1 d7a1a6a0…, same as the live file)
- ICD SM 2.8: https://www.gov.il/BlobFolder/generalpage/real_time_information_siri/he/ICD_SM_28_32.pdf (sha1 3069ea3a…, same as the live file)
- FAQ `siri-faq_1.pdf`: dated **Sept 2017**, describes the old SOAP 2.7 endpoint and is **not linked** from the current page. Treat it as outdated.

| Assumption | Verdict | Evidence |
|---|---|---|
| SIRI is free | **No fee mentioned anywhere**, but "free" is never stated explicitly either | Page, form and ICD contain no price or fee |
| Apply by signed form → ptsupport@mot.gov.il → key | ✅ Confirmed | Page: "developers or companies… sign the form and send it… a user code will be received in reply" |
| Individuals can apply | ⚠️ Partly | Page says "developers or companies", but the form has fields for **corporation name** and **corporation number** (שם התאגיד / מספר התאגיד), plus Hebrew full name and ID number (ת"ז) + signature. Whether a private individual may leave the corporation fields blank is **unverified**; ask ptsupport |
| Static IP required | ✅ Confirmed | Form: "*מספר IP סטטי" with "contact your ISP for a static IP"; FAQ Q15 (2017): mandatory for security reasons; FAQ Q10b: change IP by e-mail |
| Must be an Israeli IP | ❓ **Not stated anywhere** in the official documents | none |
| Terms = liability disclaimer only; commercial use OK; no attribution | ⚠️ The terms on the form are **only** a liability disclaimer (the ministry isn't liable for damage or data errors). There is **no** commercial-use clause and **no** attribution clause, so nothing forbids commercial use, but nothing explicitly grants it either | Form "תנאי שימוש" section |
| No rate limit | ❓ **None stated** in the page, form or ICD. A 2015 community forum post mentions 1,500 req/min; unofficial | ICD has no rate or frequency section |
| Endpoint is `moran.mot.gov.il/...` | ⚠️ **Not in official docs**: ICD §7.4 says "the Request address will be given to the Developer by Email". `moran.mot.gov.il` comes from community code (hasadna, better-rail) | Live check: resolves to 34.165.60.250 (Google LLC), and HTTPS from a non-registered IP **times out** (consistent with a network-level allow-list; not proof) |
| SIRI-Lite HTTP GET, JSON or XML | ✅ Confirmed | ICD §7.1, §7.7, version 2.8 changelog "Add support for JSON response" |
| Per-line query of every bus: `MonitoringRef=all&LineRef=X` | ✅ Confirmed | ICD §7.12.9, §7.14 |
| National snapshot `AllActiveTripsFilter` | ✅ Confirmed | ICD §7.15–7.16 (JSON only) |
| Fields: plate (VehicleRef), speed (Velocity), Bearing, OriginAimedDepartureTime, RecordedAtTime, DistanceFromStop, vehicle location | ✅ Confirmed (field table in ICD §8; VehicleRef = "vehicle number" per page and ICD §1.6.1) | ICD field table |
| "Vehicle number" = licence plate | ⚠️ The ICD says "vehicle number" per the licensing system; plate equivalence is from community data (Stride/Hasadna label it plate) | — |
| 3-trips-per-line limit | ✅ **Removed** in 2.8 (the 2017 FAQ is outdated) | ICD changelog 30/04/2020 |
| Accessibility / occupancy in SIRI | ✅ Not in the ICD field list | ICD §8 |
| Data scope | ✅ Buses + Israel Railways (no train location), up to 4 h before departure; **Jerusalem light rail not included "at this stage"** | Page (updated 2025) |
