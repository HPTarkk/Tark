/// What an unclaimed invite seat is called, and how to recognise one later.
///
/// One-scan entry forces the host to open a seat *before* it can know who will
/// take it, so the roster gets a row with a name nobody chose. That name is
/// durable, and it outlives the moment it was true: it is still sitting there
/// when the seat's owner turns up.
///
/// This lives in the domain rather than beside the widget that renders it
/// because two non-presentation callers have to reason about it. The live
/// session will not put a placeholder on the wire as though it were somebody's
/// name, and the seat confirmer will overwrite one but never a real name. Both
/// are decisions about stored data, not about pixels.
///
/// Every language is listed, not just the current one. The stored string is
/// frozen in whichever locale the host was using when the seat was opened, and
/// the phone reading it may not be in that locale.
library;

/// Deliberately literal, and the one string in the app that stays out of the
/// ARB files.
///
/// It is a **durable stored value**, not display copy: the host writes it into
/// the seat record, and `roomMemberDisplayName` has to recognise it later on a
/// phone that may be running the other language. `AppLocalizations` only ever
/// knows what the *reader* is set to, so resolving it there would leave a seat
/// opened in Persian unrecognisable to an English reader — and the row would
/// go on claiming to be free after somebody sat in it.
String heldSeatNameFor({required bool fa}) => fa ? 'جای خالی' : 'Open seat';

/// Whether [name] is a placeholder this app wrote rather than a chosen name.
bool isHeldSeatPlaceholder(String name) =>
    _heldSeatPlaceholders.contains(name.trim());

const _heldSeatPlaceholders = {'Open seat', 'جای خالی'};
