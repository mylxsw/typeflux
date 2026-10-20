# Quick Ask in the launcher

Type `qa` followed by a space to enter Quick Ask, or enter `qa <question>` and press Return. The question is sent only on explicit submission. Return sends; Shift+Return inserts a newline; IME confirmation does not send.

The launcher displays a streaming Markdown answer with copy, stop, and new-question actions. Continue asking and Open in Chat both open the same conversation; Command+O is the keyboard equivalent. Opening Chat never repeats the initial request and preserves an existing chat draft. The chat composer receives focus so a follow-up can be typed immediately.

Quick Ask uses the launcher's selected model and storage choice. Selected-text context follows its existing inclusion setting. Screenshots are not sent automatically. Attachments, skills, MCP selections, and tool execution belong in Chat; the Open in Chat action transfers an unsent advanced draft intact. A generated answer remains part of normal history unless the conversation is temporary.

Esc closes transient UI first, then stops a running answer, then exits Quick Ask, then closes the launcher. After a submitted question, exiting the mode clears the launcher input because the question is already in its conversation. Hiding the launcher stops an untransferred run and retains its session for reopening. A run transferred to Chat continues there. Account changes clear the inline session; reopening never automatically sends a question again.

The keyword can be renamed or disabled in Settings → Launcher → Keywords. Existing user keywords and workflows retain precedence over the new default.

## Implementation

`AskQuickAskPlugin` registers the explicit entry. `AskQuickAskSession` stores presentation identity and the submitted draft; `AskConversationModel` continues to own the transcript, persistence, cancellation, and stream. An inline submission does not change Chat's selected conversation or draft. The generation token isolates asynchronous model validation from independent Chat navigation. Tool restrictions belong to the request driver and survive a window handoff.

`AskQuickAskView` reads the shared conversation snapshot and the actual launcher viewport. Its footer remains visible in short windows. Committed assistant messages replace their corresponding stream previews, and server failures appear inline even when no client exception occurs.
