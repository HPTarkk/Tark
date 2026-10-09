// Exact bilingual FAQ copy from the current Tarkk website.
export const faqItems = [
  {
    enQuestion:
      "Two groups of us are on the same WiFi. Will we hear each other?",
    faQuestion: "دو گروهیم روی یه وای‌فای. صدای همدیگه رو می‌شنویم؟",
    enAnswer:
      "Not if each group starts its own channel. Starting one gives it a short code, and Tarkk ignores anyone on a different code — so two groups on one café router stay two conversations. The code travels inside the same QR the other phone already scans, and it is short enough to read out loud if the camera is not handy. Worth knowing: it keeps channels apart, it does not lock them. Anyone who has the code can use it, so treat it as a channel number rather than a password.",
    faAnswer:
      "نه، اگه هر گروه کانال خودش رو بسازه. وقتی کانال می‌سازی یه کد کوتاه می‌گیره و «ترک» هر کسی رو که روی کد دیگه‌ایه نادیده می‌گیره — پس دو گروه روی یه مودم کافه، دو تا گفت‌وگوی جدا می‌مونن. این کد داخل همون کد دعوتی می‌ره که گوشی مقابل به‌هرحال اسکن می‌کنه، و اون‌قدر کوتاه هست که اگه دوربین دم دست نبود بشه بلند خوندش. اینم بدون: کانال‌ها رو از هم جدا می‌کنه، ولی قفلشون نمی‌کنه. هر کسی کد رو داشته باشه می‌تونه ازش استفاده کنه، پس مثل شماره کانال بهش نگاه کن، نه رمز.",
  },
  {
    enQuestion: "Which connection should I pick?",
    faQuestion: "کدوم نوع اتصال رو انتخاب کنم؟",
    enAnswer:
      "You don't have to pick one. Tarkk asks a single question — are you starting a channel, or joining one? — and works out the rest from what your phone can see: the WiFi you're already on, otherwise a hotspot one phone makes and the other scans, and Bluetooth where neither is possible. Each button tells you which way it's about to go, so nothing happens that the screen didn't say first. If you'd rather choose yourself, you still can, in Settings → Advanced settings.",
    faAnswer:
      "لازم نیست خودت انتخاب کنی. «ترک» فقط یه سؤال می‌پرسه — داری کانال می‌سازی یا وارد یکی می‌شی؟ — و بقیه‌ش رو از روی چیزی که گوشیت می‌بینه تشخیص می‌ده: وای‌فایی که روش هستی، وگرنه هات‌اسپاتی که یه گوشی می‌سازه و اون یکی کدش رو اسکن می‌کنه، و بلوتوث وقتی هیچ‌کدوم ممکن نیست. هر دکمه خودش می‌گه از کدوم راه می‌ره، پس هیچ اتفاقی نمی‌افته که صفحه از قبل نگفته باشه. اگه ترجیح می‌دی خودت انتخاب کنی، هنوز هم می‌تونی: تنظیمات ← تنظیمات پیشرفته.",
  },
  {
    enQuestion: "Do I have to set the connection up before I open a room?",
    faQuestion: "قبل از باز کردن اتاق باید اتصال رو خودم برقرار کنم؟",
    enAnswer:
      "No. Scanning the invite is the setup: the two phones find each other over Bluetooth, the phone that showed the code brings a hotspot up, the other joins it, and both go on air by themselves — nobody has to decide who hosts. If Android asks the joining phone whether to connect to a network, say yes. A room only counts as connected once another member has answered a signed challenge over the link the call is actually using, so being on WiFi — even the same WiFi — never counts on its own. With no scan to work from, Start tries whatever link the phone already has; if that doesn't reach anyone, it says so and offers to connect the phones by hand.",
    faAnswer:
      "نه. اسکن کد دعوت یعنی همه‌ی کار: دو گوشی با بلوتوث همدیگر را پیدا می‌کنند، گوشی‌ای که کد را نشان داده هات‌اسپات را روشن می‌کند، آن یکی به آن وصل می‌شود و هر دو خودشان وارد ارتباط می‌شوند — لازم نیست کسی تصمیم بگیرد میزبان کیست. اگر اندروید روی گوشی دوم پرسید به شبکه وصل شود یا نه، «اتصال» را بزنید. اتاق فقط وقتی «وصل» حساب می‌شود که یکی دیگر از اعضا روی همان مسیری که صدا از آن می‌رود به یک چالش امضاشده جواب داده باشد؛ پس روی وای‌فای بودن — حتی همان وای‌فای — به‌تنهایی حساب نیست. اگر اسکنی در کار نباشد، «شروع ارتباط» همان اتصالی را که گوشی دارد امتحان می‌کند، و اگر به کسی نرسید همین را می‌گوید و پیشنهاد می‌دهد گوشی‌ها را دستی به هم وصل کنید.",
  },
  {
    enQuestion: "Do I need an account or an internet connection?",
    faQuestion: "آیا به ساختن حساب یا اینترنت نیاز دارم؟",
    enAnswer:
      "Not to talk. Tarkk goes straight between phones over WiFi or Bluetooth — no internet, no data plan. An account is only needed to subscribe to the paid features; talking over Bluetooth is free and needs none.",
    faAnswer:
      "برای حرف زدن، نه. تَرک مستقیم با وای‌فای یا بلوتوث گوشی‌ها رو به هم وصل می‌کنه — نه اینترنت می‌خواد، نه بسته‌ی اینترنت. حساب فقط برای خرید اشتراک قابلیت‌های پولی لازمه؛ حرف زدن با بلوتوث رایگانه و حساب نمی‌خواد.",
  },
  {
    enQuestion: "Does Tarkk collect my data?",
    faQuestion: "آیا «ترک» اطلاعات من رو جمع می‌کنه؟",
    enAnswer:
      "Your voice never leaves the link between the phones — no server ever carries it, ours included. The app sends no analytics or usage stats, and its diagnostic log stays on your phone unless you choose to share it. If you make an account to subscribe, our server keeps your email, name, avatar and subscription; the Privacy Policy lists all of it.",
    faAnswer:
      "صدای شما هیچ‌وقت از بین خود گوشی‌ها بیرون نمی‌ره — هیچ سروری، حتی سرور خود ما، اون رو جابه‌جا نمی‌کنه. برنامه هیچ آمار یا تحلیلی از استفاده نمی‌فرسته و لاگ عیب‌یابی‌ش روی گوشی خودت می‌مونه، مگر اینکه خودت بخوای به اشتراکش بذاری. اگه برای خرید اشتراک حساب بسازی، سرور ما ایمیل، اسم، آواتار و اشتراکت رو نگه می‌داره؛ فهرست کاملش توی سیاست حریم خصوصی هست.",
  },
  {
    enQuestion: "What if I lock my phone while talking?",
    faQuestion: "اگه صفحه گوشیمو قفل کنم قطع میشم؟",
    enAnswer:
      "The app stays awake in the background. Lock the screen or stuff your phone in a pocket — you're still on.",
    faAnswer:
      "نه، برنامه پشت صحنه بیداره. صفحه رو قفل کن یا گوشی رو بذار تو جیب — هنوز وصلی.",
  },
  {
    enQuestion: "What happens if the connection drops?",
    faQuestion: "اگه ارتباط وسط راه برای لحظه‌ای قطع بشه چی؟",
    enAnswer:
      "Tarkk keeps trying in the background and picks the call back up the second your friend is close enough again.",
    faAnswer:
      "تَرک پشت صحنه تلاشش رو می‌کنه و همین که دوباره به دوستتون نزدیک شدید، تماس رو برمی‌گردونه.",
  },
  {
    enQuestion: "Can iPhone and Android users talk to each other?",
    faQuestion: "آیا آیفون و اندروید میتونن با هم صحبت کنن؟",
    enAnswer:
      "Yep! One phone makes the hotspot, the other scans its code right inside the app — you never have to leave Tarkk. Or just send a link and they hop in from a browser.",
    faAnswer:
      "آره! یه گوشی هات‌اسپات رو می‌سازه و اون یکی کدش رو با کدخوان خود برنامه می‌خونه — اصلاً لازم نیست از «ترک» بیای بیرون. یا یه پیوند ساده بفرست تا از مرورگر بپرن تو.",
  },
  {
    enQuestion: "Does it work with absolutely no cell network?",
    faQuestion: "آیا جاهایی که اصلاً گوشی آنتن نداره هم کار میکنه؟",
    enAnswer:
      "Yes. Two Android phones link up straight over Bluetooth — no internet, no router, no signal at all.",
    faAnswer:
      "آره. دو تا گوشی اندروید مستقیم با بلوتوث به هم وصل می‌شن؛ نه مودم می‌خواد، نه اینترنت، نه حتی سیم‌کارت.",
  },
  {
    enQuestion: "Is my voice clear and high quality?",
    faQuestion: "آیا کیفیت صدا خوب و واضح هست؟",
    enAnswer:
      "Yep. Your voice gets shrunk down in a clever way that keeps it crystal clear, and the smart cleaner wipes out wind, traffic and background noise before it ever leaves your phone. If a piece goes missing on the way — normal on any wireless link — the next one carries a spare copy, so the gap gets filled instead of chopping a word in half. The app keeps adjusting to the link as you ride, so you never have to touch a setting.",
    faAnswer:
      "آره. صدا طوری کوچیک می‌شه که شفاف بمونه، و پاک‌کن هوشمند صدای باد و ترافیک و سروصدای اطراف رو قبل از اینکه از گوشی بره بیرون پاک می‌کنه. اگه تیکه‌ای از صدا تو راه گم بشه — که تو هر اتصال بی‌سیمی عادیه — تیکه بعدی یه نسخه یدک ازش همراه داره، پس جای خالی پر می‌شه به‌جای اینکه وسط کلمه بریده بشه. برنامه هم همین‌طور که تو راهید خودش رو با شرایط تنظیم می‌کنه، پس لازم نیست دست به هیچ تنظیمی بزنید.",
  },
  {
    enQuestion: "My hotspot keeps dropping. Why?",
    faQuestion: "هات‌اسپاتم مدام قطع می‌شه. چرا؟",
    enAnswer:
      "Almost always because Wi-Fi is still on. A phone can't do Wi-Fi and a hotspot properly at the same time, so sooner or later one of them gives way — usually your hotspot, right in the middle of a ride. Tarkk spots this and offers you a one-tap switch while you're still on the code screen. Turning Wi-Fi off won't cut you off from anyone: the channel doesn't need Wi-Fi to work.",
    faAnswer:
      "تقریباً همیشه به این خاطر که وای‌فای هنوز روشنه. گوشی نمی‌تونه همزمان هم وای‌فای وصل باشه هم هات‌اسپات درست بده، پس دیر یا زود یکیشون کوتاه میاد — معمولاً هات‌اسپاتت، درست وسط راه. «ترک» این رو تشخیص می‌ده و همون موقع که هنوز تو صفحه‌ی کد هستی یه کلید یک‌ضربه‌ای بهت می‌ده. خاموش کردن وای‌فای ارتباطت با کسی رو قطع نمی‌کنه: کانال برای کار کردن به وای‌فای احتیاجی نداره.",
  },
  {
    enQuestion: "I'm on a motorbike. Is there anything I should switch on?",
    faQuestion: "موتورسوارم. چیزی هست که باید روشن کنم؟",
    enAnswer:
      "One switch. Settings → Riding mode aims the whole thing at the road: the mic waits for you to actually talk instead of sending wind and engine noise the entire ride, the cleaner runs at a level that keeps words crisp rather than scrubbing them thin, the app holds a bit more sound in reserve so a connection on the move doesn't chop, and everyone else comes through a touch louder. Your own settings stay exactly where you left them, and come straight back the moment you switch it off.",
    faAnswer:
      "فقط یه سوییچ. تنظیمات ← حالت موتورسواری همه‌چی رو می‌چرخونه سمت جاده: میکروفون صبر می‌کنه تا واقعاً حرف بزنی، به‌جای اینکه کل مسیر صدای باد و موتور رو بفرسته؛ پاک‌کن اون‌قدری کار می‌کنه که کلمه‌ها واضح بمونن، نه اینکه نازک و بی‌جون بشن؛ برنامه یه کم صدای بیشتری ذخیره نگه می‌داره تا ارتباطِ در حال حرکت بریده‌بریده نشه؛ و صدای بقیه یه کم بلندتر می‌رسه. تنظیمات خودت هم دقیقاً سر جاش می‌مونه و همین که خاموشش کنی برمی‌گرده.",
  },
  {
    enQuestion: "What if nobody can hear me?",
    faQuestion: "اگه کسی صدامو نشنوه چی؟",
    enAnswer:
      "Tarkk tells you, in plain words, with the fix right there — whether the mic is switched off, the phone isn't on a network, or something else has grabbed the microphone. It quietly retries a few times first, so a hiccup that sorts itself out never interrupts you. And there's a “Something wrong?” button on the channel screen that shows you exactly which part isn't working.",
    faAnswer:
      "«ترک» با زبون ساده بهت می‌گه، و راه حلش هم همون‌جاست — چه میکروفون خاموش باشه، چه گوشی به شبکه‌ای وصل نباشه، چه یه برنامه دیگه میکروفون رو گرفته باشه. اول چند بار بی‌سروصدا خودش تلاش می‌کنه، تا یه گیر موقتی که خودش درست می‌شه اصلاً مزاحمت نشه. یه دکمه «مشکلی هست؟» هم توی صفحه کانال هست که دقیقاً نشونت می‌ده کدوم قسمت کار نمی‌کنه.",
  },
];
