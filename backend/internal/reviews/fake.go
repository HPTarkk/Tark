package reviews

import (
	"context"
	"fmt"
	"math/rand/v2"
	"strconv"
	"sync"
	"time"
)

// Fake is an in-memory Bazaar for development (TARK_BAZAAR_REVIEWS_FAKE) and
// tests. It serves a few hundred believable reviews, in Persian and English,
// in pages of PageSize, and approves a reply ApproveAfter after it is sent,
// so the whole flow can be seen without Bazaar's key.
type Fake struct {
	PageSize     int
	ApproveAfter time.Duration
	// Fail, when set, is returned by every call (tests).
	Fail error

	mu      sync.Mutex
	reviews []Review
	pending map[int64]pendingReply
	now     func() time.Time
	// Calls counts List and Reply calls (tests).
	Calls int
	// Sent records every reply, in order (tests).
	Sent []SentReply
}

// SentReply is one reply the fake received.
type SentReply struct {
	ReviewID    int64
	Text, Email string
}

type pendingReply struct {
	text, email string
	at          time.Time
}

// NewFake returns a fake holding n generated reviews spread over the last
// 120 days, newest first.
func NewFake(n int) *Fake {
	f := &Fake{PageSize: 25, ApproveAfter: 2 * time.Minute, pending: map[int64]pendingReply{}, now: time.Now}
	rnd := rand.New(rand.NewPCG(7, 11))
	now := time.Now().UTC()
	for i := 0; i < n; i++ {
		rate := weightedRate(rnd)
		text := fakeTexts[rate][rnd.IntN(len(fakeTexts[rate]))]
		at := now.Add(-time.Duration(float64(120*24*time.Hour) * float64(i) / float64(max(n, 1)))).Add(-time.Duration(rnd.IntN(3600)) * time.Second)
		code := 39 - min(i*8/max(n, 1), 7)
		sdk := []int{26, 28, 29, 30, 31, 33, 34, 34, 35, 35}[rnd.IntN(10)]
		likes, dislikes := rnd.IntN(12), rnd.IntN(4)
		edited := rnd.IntN(9) == 0
		r := Review{
			ID: 122280900 + int64(n-i), UserAccountID: fmt.Sprintf("%08x-%04x-4%03x-%04x-%012x", rnd.Uint32(), rnd.IntN(0xffff), rnd.IntN(0xfff), 0x8000|rnd.IntN(0x3fff), rnd.Uint64()&0xffffffffffff),
			Text: text, Rate: rate, PublishDate: &at, IsEdited: &edited, Likes: &likes, Dislikes: &dislikes,
			AppVersionCode: &code, SDKVersion: &sdk,
		}
		// Older reviews are more likely to have an answer already.
		if i > n/5 && rnd.IntN(3) > 0 {
			rat := at.Add(time.Duration(2+rnd.IntN(70)) * time.Hour)
			rl := rnd.IntN(5)
			r.Reply = &DeveloperReply{Text: fakeReplies[rnd.IntN(len(fakeReplies))], Email: "support@tarkk.ir", PublishDate: &rat, Likes: &rl}
		}
		f.reviews = append(f.reviews, r)
	}
	return f
}

func weightedRate(rnd *rand.Rand) int {
	switch n := rnd.IntN(100); {
	case n < 52:
		return 5
	case n < 70:
		return 4
	case n < 80:
		return 3
	case n < 88:
		return 2
	}
	return 1
}

func (f *Fake) List(_ context.Context, cursor string) (Page, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Calls++
	if f.Fail != nil {
		return Page{}, f.Fail
	}
	f.approve()
	start := 0
	if cursor != "" {
		n, err := strconv.Atoi(cursor)
		if err != nil || n < 0 || n > len(f.reviews) {
			return Page{}, &Error{Kind: ErrRefused, Status: 400, Detail: "Invalid cursor"}
		}
		start = n
	}
	size := f.PageSize
	if size <= 0 {
		size = 25
	}
	end := min(start+size, len(f.reviews))
	page := Page{Reviews: append([]Review(nil), f.reviews[start:end]...)}
	if end < len(f.reviews) {
		page.Next = strconv.Itoa(end)
	}
	return page, nil
}

func (f *Fake) Reply(_ context.Context, id int64, text, email string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.Calls++
	if f.Fail != nil {
		return f.Fail
	}
	for _, r := range f.reviews {
		if r.ID == id {
			if email == "" {
				email = "developer@example.com"
			}
			f.pending[id] = pendingReply{text, email, f.now()}
			f.Sent = append(f.Sent, SentReply{id, text, email})
			return nil
		}
	}
	return &Error{Kind: ErrNotFound, Status: 404, Detail: "Not found."}
}

// Add puts a review at the top, as if just written (tests).
func (f *Fake) Add(r Review) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.reviews = append([]Review{r}, f.reviews...)
}

// Remove drops a review, as if deleted on Bazaar (tests).
func (f *Fake) Remove(id int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i, r := range f.reviews {
		if r.ID == id {
			f.reviews = append(f.reviews[:i], f.reviews[i+1:]...)
			return
		}
	}
}

// Edit changes a review's text and marks it edited (tests).
func (f *Fake) Edit(id int64, text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for i := range f.reviews {
		if f.reviews[i].ID == id {
			yes := true
			f.reviews[i].Text, f.reviews[i].IsEdited = text, &yes
		}
	}
}

// approve publishes the replies that have waited long enough.
func (f *Fake) approve() {
	now := f.now()
	for id, p := range f.pending {
		if now.Sub(p.at) < f.ApproveAfter {
			continue
		}
		for i := range f.reviews {
			if f.reviews[i].ID == id {
				at := now.UTC()
				f.reviews[i].Reply = &DeveloperReply{Text: p.text, Email: p.email, PublishDate: &at}
			}
		}
		delete(f.pending, id)
	}
}

var fakeTexts = map[int][]string{
	5: {
		"عالیه! بالاخره یه واکی‌تاکی که بدون اینترنت هم کار می‌کنه.",
		"توی کوه با دوستام استفاده کردیم، صدا خیلی واضح بود. دستتون درد نکنه 🙏",
		"خیلی خوب و ساده‌ست. پیشنهاد می‌کنم.",
		"Works great on our hiking trip, no signal needed. Love it!",
		"بهترین برنامه‌ی این مدلی که نصب کردم. طراحیش هم قشنگه.",
		"عالی",
		"برای ارتباط توی کارگاه عالیه، ممنون از تیم ترک.",
	},
	4: {
		"خوبه ولی کاش برد بلوتوث بیشتر بود.",
		"Really nice app. Would love a dark widget too.",
		"کیفیت صدا خوبه، فقط بعضی وقتا وصل شدن طول می‌کشه.",
		"در کل راضی‌ام. اگه گروه‌های بزرگ‌تر رو پشتیبانی کنه عالی می‌شه.",
	},
	3: {
		"بد نیست ولی بعضی وقتا صدا قطع و وصل می‌شه.",
		"It's okay. Connecting two phones took a few tries.",
		"نسخه‌ی ویژه یه کم گرونه.",
	},
	2: {
		"روی گوشی سامسونگ من وصل نمی‌شه. لطفاً درستش کنید.",
		"After the last update the sound is choppy.",
		"هات‌اسپات رو روشن می‌کنم ولی گوشی دوم پیدا نمی‌کنه.",
	},
	1: {
		"اصلاً کار نکرد. پاکش کردم.",
		"کار نمی‌کنه! بعد از آپدیت برنامه باز نمی‌شه.",
		"Crashes every time I open it.",
	},
}

var fakeReplies = []string{
	"سلام، ممنون از نظرت! خوشحالیم که به کارت اومده 🌱",
	"سلام، ممنون که گفتی. توی نسخه‌ی بعدی بهترش کردیم؛ لطفاً به‌روزرسانی کن و اگه باز مشکل بود به support@tarkk.ir بنویس.",
	"Thanks for the feedback! We're on it.",
}
