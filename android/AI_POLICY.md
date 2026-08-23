# AI-Assisted Contributions

AI tools are allowed, but the person submitting the change remains responsible for every line.

## Required

- Understand the behavior being changed.
- Review the complete diff, including Gradle and generated-file changes.
- Build the affected target and exercise user-facing behavior.
- Disclose meaningful AI assistance in the pull request description.
- Keep prompts, transcripts, caches, and scratch files out of the repository.
- Follow `AGENTS.md`, including the password check for agent-locked files.

## Not allowed

- Unreviewed generated code.
- Fabricated APIs, tests, issue references, or dependency behavior.
- Sending credentials, tokens, cookies, private server URLs, user libraries, diagnostics, or copyrighted books to an AI service.
- Using an AI tool to bypass the agent lock or remove its marker without explicit authorization from the person directing the work.
- Hiding large unrelated rewrites inside another change.

## Agent lock

The agent lock is a workflow guardrail, not an access-control boundary. Each checkout has a user-chosen password stored only as a salted hash in the ignored `.agent-lock` file. Set it with:

```sh
./scripts/agent-lock set
```

`AGENTS.md` has the protocol an agent must follow when a task touches a protected file, and the list of files it covers.
