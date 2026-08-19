# Agent development rules

- Keep the LRS authoritative only for xAPI statements, xAPI document resources, attachments, and their integrity metadata.
- Preserve received learning records immutably; corrections use standards-defined mechanisms rather than row mutation.
- Treat xAPI 2.0 as canonical and xAPI 1.0.3 as an explicit compatibility surface.
- Use two-or-more-word `snake_case` database object names and third normal form for authoritative relational facts.
- Cross-tenant references must fail closed.
- Production statement and branch coverage must be 100%, with complete public API documentation.
- Conformance evidence must run against realistic statement, voiding, attachment, State, Agent Profile, and Activity Profile cases.
