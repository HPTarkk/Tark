# Announcements

Tarkk tells people about new things with announcements. They are not pushed
from a server. They live in one static file, `website/announcements.json`,
which goes live at `https://tarkk.ir/announcements.json` when the website is
published (`scripts/release-website.ps1`). This is the same route the update
feed takes.

## When people see them

- At launch the app fetches the file. It adds a `?t=` query so nothing serves
  a stale copy, and `website/_headers` marks the file uncacheable as well.
- The sheet only comes up on the home and room-list screens. It never comes up
  over a channel, the splash or a flow someone is in the middle of.
- The update prompt always goes first. On a launch that offers an update,
  announcements wait for the next launch, so the app interrupts at most once.
- Up to three announcements share one sheet. People swipe between them, and
  the rest wait for the next launch.
- Each announcement is shown once per phone, keyed by its `id`. To show
  changed text to people who already saw it, give it a new `id`.
- An entry with a mistake is skipped and named in the diagnostic log. The
  other entries still show. A file that is not an announcements feed at all
  shows nothing.

## The file

```json
{
  "announcements": [
    {
      "id": "signup-gift-2026-12",
      "category": "gift",
      "priority": 10,
      "audience": "signedOut",
      "startsAt": "2026-12-01T00:00:00+03:30",
      "endsAt": "2027-01-01T00:00:00+03:30",
      "title": { "en": "Three months on us", "fa": "سه ماه مهمون ما باش" },
      "body": {
        "en": "Create a free account this month and Tarkk Premium is yours for three months.",
        "fa": "این ماه یه حساب رایگان بساز و سه ماه تَرک پریمیوم مال تو."
      },
      "highlight": { "en": "3 months free", "fa": "۳ ماه رایگان" },
      "action": { "type": "signIn", "label": { "en": "Sign up free", "fa": "ثبت‌نام رایگان" } }
    }
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | 1–64 characters: lowercase letters, digits, `.`, `_`, `-`. It is permanent, because a phone that saw an id never shows it again. |
| `category` | yes | `gift`, `feature`, `news`, `tip`, `event` or `alert` (see below). |
| `title`, `body` | yes | `{ "en": "…", "fa": "…" }`, or a plain string, which counts as English. A language that is missing falls back to English. Latin digits are drawn as Persian digits in Persian. |
| `highlight` | no | A short line on a ticket stamped under the text, such as "3 months free". |
| `action` | no | The main button. Without one, the button just says "Got it". See below. |
| `audience` | no | `everyone` (default), `signedOut`, `signedIn`, `free` or `premium`. |
| `startsAt`, `endsAt` | no | ISO 8601 with a zone (`Z` or `+03:30`). Shown from `startsAt` up to, not including, `endsAt`. |
| `minBuild`, `maxBuild` | no | Only for builds in this range (build numbers, like in `update.json`). |
| `platforms` | no | Some of `android`, `ios`, `web`. Leaving it out means every platform except the web guest app. |
| `priority` | no | A whole number. Higher shows first. Ties go to the one that started most recently. |

### Actions

| `type` | Also needs | Does |
|---|---|---|
| `signIn` | | Opens sign-in / sign-up. |
| `link` | `url` (https) | Opens the page in the browser. |
| `screen` | `screen`: `settings`, `profile`, `rooms` or `advanced` | Opens that screen in the app. |

`label` is optional. Without it the button reads "Sign up", "Learn more" or
"Show me".

The app also skips an announcement it cannot act on. A `signIn` action, or a
`signedOut` audience, is never shown on a build without accounts or to
someone already signed in. `free` and `premium` only apply to builds that sell
a subscription.

### Categories

Each category has its own emblem, colour, entrance and sheet backdrop, so
people can tell what kind of news it is before they read it:

| Category | Use it for | Colour | Motion |
|---|---|---|---|
| `gift` | Offers, free periods | Amber | The box drops in and shivers, then the lid pops off in a burst of confetti. Confetti keeps drifting down the sheet. |
| `feature` | Something new in Tarkk | Lagoon | A spark ignites, spins open into a star and throws rays. Dust twinkles across the sheet. |
| `news` | General word from the team | Mint | The mast draws itself, its lamp lights and the first broadcast washes across the sheet. |
| `tip` | Ways to get more out of Tarkk | Lime | The bulb is drawn, its filament flickers on and rays fan out. A warm glow fills the sheet. |
| `event` | Things with a date | Leaf | The calendar lands, a page tears over the rings and the day is circled. |
| `alert` | Service work, known problems | Red | The beacon drops, rattles, then turns and pulses. A red glow pulses along the top. |

With reduced motion turned on, everything fades in already settled and holds
still.

## Publishing one

1. Edit `website/announcements.json`.
2. Run `flutter test test/feature/announcement/announcement_feed_file_test.dart`.
   It fails on any entry the app would skip and names the problem.
3. Publish the website. People see the announcement on their next launch.

Taking an announcement down works the same way: delete the entry, or set its
`endsAt` in the past, and publish.

Only promise what is true at the time it shows. A sign-up gift needs the
subscription it offers to actually be granted on sign-up first. The file is
public, so never put anything private in it.
