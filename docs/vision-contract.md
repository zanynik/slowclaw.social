# SlowClaw vision: understand, create, give

SlowClaw helps people pay attention to their lives long enough to understand something from them, then turn that understanding into something they can give to someone else. Journaling is the starting point, not a content-production obligation. A useful result may be a clearer question, a changed belief, a private letter, a public work, or time offered to another person.

The long arc is **live → journal → understand → create → give → live again**. The existing capture, journal-driven Reads, Create, and Nostr flows are early expressions of this direction. This document describes product intent; it does not claim that the future capabilities below already ship.

## Product principles

- **The person owns the meaning.** AI may retrieve, connect, and propose; it must not silently decide what an experience meant, speak in the user's name, or publish for them.
- **Notice before generating.** Surface recurring themes, changing views, concrete experiences, contradictions, and gaps in thinking. A thoughtful question may be more useful than another draft.
- **Keep the source visible.** A proposed passage should point back to the journal moments that support it. Make uncertainty and interpretation apparent; do not invent lived experiences or present a model's phrasing as the user's own words.
- **Make change reviewable.** Preserve a canonical user-approved work. AI proposes bounded additions, edits, moves, or questions with a clear diff and reason. The user can accept, edit, or discard them; prior versions remain recoverable.
- **Let private understanding stay private.** Creating, exporting, and publishing are separate choices. A journal moment's presence in a draft never implies permission to share it, especially when it mentions other people.
- **Make giving wider than posting.** Writing, audio, art, conversation, mentorship, and attention can all be useful contributions. Do not turn every insight into a social post.

## Expressions at different timescales

| Scale | Possible expression | Role of SlowClaw |
|---|---|---|
| Moments | Quote card, short audio or video story, post | Find a grounded excerpt and offer an editable, discardable draft. |
| Works | Essay, letter collection, podcast series, book, documentary | Help maintain an evolving structure and suggest small, sourced changes over months or years. |
| Legacy | Letters, recordings, stories, a body of thought | Let people preserve and curate what they choose to pass on. |

A single journal moment could inform several expressions without being copied into all of them automatically. **Works** is a possible umbrella for long-lived projects, not a commitment to rename the current Create tab.

## A living book

Years of journals may reveal a possible book before its author has outlined one. SlowClaw could propose a theme, supporting moments, open questions, and a tentative chapter map. Starting that work is the user's decision.

Once started, the book has one canonical, user-approved version. A journal entry can lead to a small proposed patch to a specific chapter, or to a prompt to journal further. For example:

> **Chapter: Work and enough**
>
> Proposed addition: a short example that makes the current argument concrete.
>
> Sources: three selected journal moments.
>
> Why here: the chapter raises this question but has no lived example.
>
> **Accept · Edit · Discard**

If the same unresolved question recurs, the better suggestion may be “What experience would change your mind?” with an option to journal on it. An apparent contradiction might represent growth; show both dated views before suggesting a rewrite.

The small-patch approach protects voice and structure across model changes. Each proposal needs a target, source references, a reason, a visible diff, and a reversible acceptance. The human can write directly at any time. The model is an assistant to the work, never its author of record.

## How the current surfaces fit

- **Journal:** record lived experience in the person's own words, including uncertainty and unfinished thoughts.
- **Profile:** make recurring interests and shifts in understanding legible without declaring a fixed identity.
- **Reads:** encounter outside ideas through the lens of the journals and let them challenge existing thinking.
- **Create:** offer reviewable expressions, from today's quote cards and stories to possible future Works.
- **Pulse:** encounter other people and their perspectives without making popularity the measure of value.

The near-term path is to make existing moments reliable, grounded, editable, and explicitly published. Long-lived Works, guided questions, and other ways of giving remain product directions to explore incrementally with real users. The choice of classifier, embedding model, or language model should serve these principles rather than define them.
