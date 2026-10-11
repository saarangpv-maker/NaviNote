# NaviNote

**An AI-powered accessibility app prototype exploring greater independence in everyday shopping and payments.**

NaviNote brings together a vision for currency recognition, checkout assistance, and a conversational assistant named **Astra**. A planned lightweight smart cane extends that vision into a future hardware companion.

> **Project status:** Early prototype / MVP planning. This README describes the intended product direction. No working implementation, tested accuracy, or hardware integration has been verified for this public release. Features below are goals unless supported by code and documented tests added to this repository.

## The problem

For people who are blind or have low vision, identifying banknotes, understanding a checkout total, reviewing receipts, and checking returned change can require assistance from another person. NaviNote aims to make these everyday interactions more accessible through a simple conversational experience.

## Capabilities and implementation status

| Capability | Intended experience | Current status |
| --- | --- | --- |
| USD / AED currency recognition | Help identify the denomination of US dollar and UAE dirham banknotes. | Prototype scope; implementation and accuracy unverified. |
| Checkout / payment assistance | Help users understand checkout information and the steps involved in paying. | Prototype scope; implementation unverified. Payment processing is not established. |
| Astra conversational assistant | Provide an accessible way to ask questions and receive assistance. | Named product concept; implementation unverified. |
| Receipt item analysis | Explain receipt items and totals. | Planned. |
| Change verification | Compare the expected change with the notes scanned by the user. | Planned. |
| Guided multi-note scanning | Guide users through scanning several banknotes and reviewing a combined total. | Planned. |
| Lightweight smart cane | Explore a hardware companion for the accessibility experience. | Planned hardware concept; no built device or integration verified. |

### What is implemented?

There is currently no verified implementation evidence available for this README. The project is described as a prototype, but that label does not establish which capabilities work. As source code and demonstrations are added, this section should identify the working features, setup instructions, limitations, and supporting tests.

## Roadmap

1. **Establish a documented MVP:** Add the prototype source, reproducible setup instructions, and a demonstration of verified functionality.
2. **Validate the core app experience:** Develop and test USD / AED note recognition, checkout assistance, and Astra with accessible interactions and clear uncertainty handling.
3. **Expand shopping support:** Add receipt item analysis, change verification, and guided multi-note scanning.
4. **Explore the smart cane:** Define hardware requirements, build a lightweight prototype, and evaluate any app integration.
5. **Evaluate with users:** Seek feedback from people who are blind or have low vision; document usability, recognition accuracy, and failure cases before making reliability claims.

These are proposed milestones, not commitments to specific release dates.

## Privacy and security

The following are design requirements for future implementation, not claims about protections already in place:

- **Minimize collection:** Use only the images and information needed for the requested task. Receipts and checkout images may contain personal or financial information.
- **Be transparent:** Explain whether images, audio, or text are processed on the device or sent to external services, and document retention and deletion behavior.
- **Protect credentials:** Keep API keys, access tokens, passwords, and private configuration out of the public repository. Any future setup should use environment variables and examples with placeholder values.
- **Keep payments under user control:** Do not request banking passwords, PINs, or full card details. Any future transaction capability requires a separately documented, secure design and explicit user authorization.
- **Communicate uncertainty:** Currency recognition and change calculations must make uncertain results clear and support user verification. This prototype has no established financial or navigation safety guarantees.
- **Use safe public examples:** Include only synthetic or appropriately redacted sample images and receipts; do not publish personal data.

## Repository and getting started

Public repository: [saarangpv-maker/NaviNote](https://github.com/saarangpv-maker/NaviNote)

Installation and usage instructions will be added when the runnable prototype and its dependencies are available. This README does not imply that the repository currently contains a working application.

## Feedback

Feedback on accessibility needs, shopping workflows, and the proposed feature set is welcome through this repository's Issues, if enabled. Please avoid including personal or financial information in public reports.
