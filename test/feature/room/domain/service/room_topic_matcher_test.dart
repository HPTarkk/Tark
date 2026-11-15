import 'package:flutter_test/flutter_test.dart';
import 'package:tark/feature/room/domain/service/room_name_suggester.dart';
import 'package:tark/feature/room/domain/service/room_topic_matcher.dart';

void main() {
  setUp(RoomTopicMatcher.clearCache);

  /// Checks every case and reports all the misses at once.
  void expectTopics(Map<String, RoomTopic?> cases) {
    final misses = [
      for (final MapEntry(key: name, value: topic) in cases.entries)
        if (RoomTopicMatcher.match(name) case final got when got != topic)
          '«$name»: expected ${topic?.name}, got ${got?.name}',
    ];
    expect(misses, isEmpty);
  }

  group('Persian', () {
    test('people', () {
      expectTopics({
        'خانواده': RoomTopic.family,
        'خانوادهٔ رضایی': RoomTopic.family,
        'گروه خانوادگی': RoomTopic.family,
        'فک و فامیل': RoomTopic.family,
        'دخترخاله‌ها': RoomTopic.family,
        'مامان و بابا': RoomTopic.family,
        'اکیپ پدرام': RoomTopic.friends,
        'رفقا': RoomTopic.friends,
        'رفیقای قدیمی': RoomTopic.friends,
        'دوستان': RoomTopic.friends,
        'دوستای دبیرستان': RoomTopic.school,
        'بچه‌ها': RoomTopic.friends,
        'بچه ها': RoomTopic.friends,
        'بر و بچ': RoomTopic.friends,
        'یاران': RoomTopic.friends,
        'تیم پدرام': RoomTopic.friends,
        'عشقم': RoomTopic.love,
        'ما دوتا': RoomTopic.love,
        'همسایه‌ها': RoomTopic.neighbors,
        'ساختمان گلستان': RoomTopic.neighbors,
        'هم‌خونه‌ای‌ها': RoomTopic.home,
      });
    });

    test('work and learning', () {
      expectTopics({
        'همکاران': RoomTopic.work,
        'محل کار': RoomTopic.work,
        'شرکت آلفا': RoomTopic.work,
        'جلسه هفتگی': RoomTopic.work,
        'هیئت مدیره': RoomTopic.work,
        'مدرسه': RoomTopic.school,
        'همکلاسی‌ها': RoomTopic.school,
        'هم کلاسی ها': RoomTopic.school,
        'کلاس زبان': RoomTopic.school,
        'ورودی ۹۸': RoomTopic.school,
        'دانشگاه تهران': RoomTopic.university,
        'خوابگاه': RoomTopic.university,
        'دانشجوهای ارشد': RoomTopic.university,
        'کنکوری‌ها': RoomTopic.study,
        'درس خوندن': RoomTopic.study,
        'برنامه‌نویس‌ها': RoomTopic.coding,
        'کارگاه ساختمانی': RoomTopic.construction,
        'کارگاه آموزشی': RoomTopic.event,
        'پیک‌ها': RoomTopic.delivery,
        'مغازه': RoomTopic.business,
        'کارخانه': RoomTopic.factory,
      });
    });

    test('outdoors and on the move', () {
      expectTopics({
        'کوهنوردی جمعه': RoomTopic.hiking,
        'کوه‌نوردی': RoomTopic.hiking,
        'کوه': RoomTopic.hiking,
        'صعود دماوند': RoomTopic.hiking,
        'عقاب‌های کوهستان': RoomTopic.hiking,
        'کمپینگ شمال': RoomTopic.camping,
        'جنگل': RoomTopic.camping,
        'پیک‌نیک': RoomTopic.picnic,
        'پیک نیک': RoomTopic.picnic,
        'سیزده‌بدر': RoomTopic.picnic,
        'سفر کیش': RoomTopic.beach,
        'کویرنوردی': RoomTopic.desert,
        'دوچرخه‌سواری': RoomTopic.cycling,
        'دوچرخه سواران': RoomTopic.cycling,
        'موتورسواران': RoomTopic.motorcycle,
        'آفرود': RoomTopic.offroad,
        'ماشین‌بازها': RoomTopic.car,
        'کاروان نیمه‌شب': RoomTopic.car,
        'سفر جاده‌ای': RoomTopic.car,
        'جادهٔ شمال': RoomTopic.car,
        'شمال': RoomTopic.beach,
        'سفر': RoomTopic.travel,
        'سفرهای تابستونی': RoomTopic.travel,
        'هم‌سفرها': RoomTopic.travel,
        'همسفرها': RoomTopic.travel,
        'هم سفرها': RoomTopic.travel,
        'مسافرت': RoomTopic.travel,
        'گشت و گذار': RoomTopic.travel,
        'تور استانبول': RoomTopic.tour,
        'پرواز': RoomTopic.flight,
        'قطار': RoomTopic.train,
        'اسکی دیزین': RoomTopic.skiing,
        'ماهیگیری': RoomTopic.fishing,
        'پاراگلایدر': RoomTopic.paragliding,
      });
    });

    test('sports and play', () {
      expectTopics({
        'فوتبال': RoomTopic.football,
        'فوتبال پنجشنبه': RoomTopic.football,
        'بچه‌های فوتبال': RoomTopic.football,
        'گل کوچیک': RoomTopic.football,
        'پرسپولیسی‌ها': RoomTopic.football,
        'والیبال': RoomTopic.volleyball,
        'بسکتبال': RoomTopic.basketball,
        'باشگاه': RoomTopic.gym,
        'بدنسازی': RoomTopic.gym,
        'باشگاه کتاب': RoomTopic.books,
        'کشتی‌گیرها': RoomTopic.martialArts,
        'تکواندو': RoomTopic.martialArts,
        'گیمرها': RoomTopic.gaming,
        'پابجی': RoomTopic.gaming,
        'کالاف': RoomTopic.gaming,
        'پی‌اس ۵': RoomTopic.gaming,
        'شب بازی': RoomTopic.gaming,
        'برف‌بازی': RoomTopic.snow,
        'مافیا': RoomTopic.boardGames,
        'اسم فامیل': RoomTopic.boardGames,
        'شطرنج': RoomTopic.boardGames,
        'لیگ': RoomTopic.tournament,
        'ورزش صبحگاهی': RoomTopic.sports,
      });
    });

    test('life and celebrations', () {
      expectTopics({
        'تولد سارا': RoomTopic.birthday,
        'جشن تولد': RoomTopic.birthday,
        'عروسی': RoomTopic.wedding,
        'دورهمی': RoomTopic.party,
        'دورهمی خانوادگی': RoomTopic.party,
        'شب یلدا': RoomTopic.party,
        'نوروز': RoomTopic.party,
        'مهمونی': RoomTopic.party,
        'کافه گردی': RoomTopic.cafe,
        'شام جمعه': RoomTopic.food,
        'سفره': RoomTopic.food,
        'جوجه کباب': RoomTopic.bbq,
        'کنسرت': RoomTopic.music,
        'شب فیلم': RoomTopic.movies,
        'مسجد محل': RoomTopic.religion,
        'هیئت': RoomTopic.religion,
        'ختم قرآن': RoomTopic.religion,
        'مراسم ختم': RoomTopic.mourning,
        'خیریه': RoomTopic.charity,
        'سگ‌ها': RoomTopic.pets,
        'گربه': RoomTopic.pets,
        'مهدکودک': RoomTopic.baby,
        'بچه': RoomTopic.baby,
      });
    });

    test('safety', () {
      expectTopics({
        'اورژانس': RoomTopic.emergency,
        'امداد و نجات': RoomTopic.emergency,
        'هلال احمر': RoomTopic.emergency,
        '۱۱۵': RoomTopic.emergency,
        'آتش‌نشانی': RoomTopic.firefighters,
        'آتش نشانی': RoomTopic.firefighters,
        'پلیس': RoomTopic.police,
        'بیمارستان': RoomTopic.medical,
        'دکتر': RoomTopic.medical,
        'سربازی': RoomTopic.military,
        // Emergencies outrank everything else in the name.
        'اورژانس خانواده': RoomTopic.emergency,
      });
    });

    test('evocative crew names', () {
      expectTopics({
        'گرگ‌های کویر': RoomTopic.animals,
        'جغدهای شب': RoomTopic.night,
        'شب‌گردها': RoomTopic.night,
        'طوفان‌گردها': RoomTopic.storm,
        'اکیپ رعد': RoomTopic.lightning,
        'ستاره‌های دنباله‌دار': RoomTopic.stars,
        'اکیپ آتش': RoomTopic.fire,
        'سواران غروب': RoomTopic.sunset,
        'پلنگ‌های برفی': RoomTopic.animals,
        'شیرهای جاده': RoomTopic.animals,
        'اکیپ پژواک': RoomTopic.echo,
        'بی‌سیمچی‌ها': null,
        'بی سیم': RoomTopic.radio,
      });
    });
  });

  group('English', () {
    test('people, work and learning', () {
      expectTopics({
        'Family': RoomTopic.family,
        'The Fam': RoomTopic.family,
        'Cousins': RoomTopic.family,
        'Best Friends': RoomTopic.friends,
        "Pedram's Crew": RoomTopic.friends,
        'Squad': RoomTopic.friends,
        'Pedram & Co.': RoomTopic.friends,
        'Office': RoomTopic.work,
        'Coworkers': RoomTopic.work,
        'Night shift': RoomTopic.work,
        'Class of 2024': RoomTopic.school,
        'Classmates': RoomTopic.school,
        'Uni friends': RoomTopic.university,
        'Dorm 4': RoomTopic.university,
        'Dev team': RoomTopic.coding,
        'Book club': RoomTopic.books,
        'Neighbours': RoomTopic.neighbors,
        'Roommates': RoomTopic.home,
        'Honey': RoomTopic.love,
      });
    });

    test('outdoors, sports and travel', () {
      expectTopics({
        'Hiking': RoomTopic.hiking,
        'Weekend Hikers': RoomTopic.hiking,
        'Mountain Goats': RoomTopic.hiking,
        'Camping trip': RoomTopic.camping,
        'Campfire': RoomTopic.camping,
        'Cycling club': RoomTopic.cycling,
        'Bikers': RoomTopic.motorcycle,
        "Pedram's Road Trip": RoomTopic.car,
        'RoadTrip': RoomTopic.car,
        'road_trip_2025': RoomTopic.car,
        'Midnight Convoy': RoomTopic.car,
        'Off-road 4x4': RoomTopic.offroad,
        'Ski trip': RoomTopic.skiing,
        'Snowboarders': RoomTopic.snowboarding,
        'Beach day': RoomTopic.beach,
        'Europe travel': RoomTopic.travel,
        'Trip to Paris': RoomTopic.travel,
        'Flight crew': RoomTopic.flight,
        'Football': RoomTopic.football,
        'Sunday soccer': RoomTopic.football,
        'American football': RoomTopic.americanFootball,
        'Basketball': RoomTopic.basketball,
        'Gym bros': RoomTopic.gym,
        'Road Runners': RoomTopic.running,
        '5k run': RoomTopic.running,
        'Fishing': RoomTopic.fishing,
      });
    });

    test('play, life and celebrations', () {
      expectTopics({
        'Gamers': RoomTopic.gaming,
        'PUBG squad': RoomTopic.gaming,
        'Call of Duty': RoomTopic.gaming,
        'PS5': RoomTopic.gaming,
        'League of Legends': RoomTopic.gaming,
        'Board games': RoomTopic.boardGames,
        'Lucky Sevens': RoomTopic.boardGames,
        'Band practice': RoomTopic.music,
        'Movie night': RoomTopic.movies,
        "Sara's Birthday": RoomTopic.birthday,
        'Bday': RoomTopic.birthday,
        'Wedding': RoomTopic.wedding,
        'Party': RoomTopic.party,
        'Nowruz': RoomTopic.party,
        'Dinner': RoomTopic.food,
        'Coffee': RoomTopic.cafe,
        'Café': RoomTopic.cafe,
        'BBQ': RoomTopic.bbq,
        'Pizza Friday': RoomTopic.pizza,
        'Dog walkers': RoomTopic.walking,
        'Dogs': RoomTopic.pets,
        'Kids': RoomTopic.baby,
        'Emergency': RoomTopic.emergency,
        'SOS': RoomTopic.emergency,
        'Family emergency': RoomTopic.emergency,
        'Hospital': RoomTopic.medical,
      });
    });

    test('evocative crew names', () {
      expectTopics({
        'Night Owls': RoomTopic.night,
        'Desert Wolves': RoomTopic.animals,
        'Wolf Pack': RoomTopic.animals,
        'Thunder Crew': RoomTopic.lightning,
        'Storm Chasers': RoomTopic.storm,
        'Wild Comets': RoomTopic.stars,
        'Northern Lights': RoomTopic.stars,
        'Silver Foxes': RoomTopic.animals,
        'Sky Pirates': RoomTopic.sailing,
        'Echo Squad': RoomTopic.echo,
        'Sunset Riders': RoomTopic.motorcycle,
        'Snow Leopards': RoomTopic.animals,
        'Rolling Thunder': RoomTopic.lightning,
      });
    });
  });

  test('Finglish', () {
    expectTopics({
      'khanevade': RoomTopic.family,
      'rafigha': RoomTopic.friends,
      'safar': RoomTopic.travel,
      'koohnavardi': RoomTopic.hiking,
      'dorehami': RoomTopic.party,
      'daneshgah': RoomTopic.university,
      'sherkat': RoomTopic.work,
      'futbal': RoomTopic.football,
    });
  });

  group('emoji', () {
    test('an emoji names the topic outright', () {
      expectTopics({
        '⚽': RoomTopic.football,
        '⚽️ خانواده': RoomTopic.football,
        'Family 🏕️': RoomTopic.camping,
        '🎮 night': RoomTopic.gaming,
        'رفقا ❤️': RoomTopic.love,
        '🚗💨': RoomTopic.car,
        '👨‍👩‍👧': RoomTopic.family,
        '🎂': RoomTopic.birthday,
        '🆘': RoomTopic.emergency,
      });
    });

    test('an emoji with no meaning leaves the words to decide', () {
      expectTopics({'🙂 کوه': RoomTopic.hiking, '🙂': null});
    });
  });

  group('spelling variants', () {
    test('Arabic letter forms read as Persian ones', () {
      // ي and ك in place of ی and ک, as some keyboards type them.
      expectTopics({
        'كوهنوردي': RoomTopic.hiking,
        'خانواده ي ما': RoomTopic.family,
        'دوستان قديمي': RoomTopic.friends,
        'هيئت': RoomTopic.religion,
        'مدرسة': RoomTopic.school,
      });
    });

    test('half-space, space and joined read the same', () {
      for (final name in ['هم‌سفرها', 'هم سفرها', 'همسفرها']) {
        expect(RoomTopicMatcher.match(name), RoomTopic.travel, reason: name);
      }
    });

    test('harakat, tatweel and the hamza above are ignored', () {
      expectTopics({
        'خـــانواده': RoomTopic.family,
        'سَفَر': RoomTopic.travel,
        'خانهٔ ما': RoomTopic.home,
      });
    });

    test('Persian and Arabic digits read as ASCII', () {
      expect(RoomTopicMatcher.normalize('ورودی ۹۸'), 'ورودی 98');
      expect(RoomTopicMatcher.normalize('ورودی ٩٨'), 'ورودی 98');
      expectTopics({'۱۱۲': RoomTopic.emergency, 'PS۵': RoomTopic.gaming});
    });

    test('case, camelCase and punctuation are ignored', () {
      expect(
        RoomTopicMatcher.normalize('  Road_Trip-2025!!  '),
        'road trip 2025',
      );
      expect(RoomTopicMatcher.normalize('FamilyTrip'), 'family trip');
      expectTopics({
        'HIKING': RoomTopic.hiking,
        '#football': RoomTopic.football,
        'family.trip': RoomTopic.travel,
      });
    });
  });

  group('whole words only', () {
    test('a word inside another word is not matched', () {
      expectTopics({
        // «کار» (work) inside «کاروان» (convoy).
        'کاروان': RoomTopic.car,
        // «سفر» (trip) inside «سفره» (a meal spread).
        'سفره': RoomTopic.food,
        // «شیر» (lion) inside «شیرینی» (sweets).
        'شیرینی': RoomTopic.food,
        // «درس» (study) inside the name «درسا».
        'اکیپ درسا': RoomTopic.friends,
        // «فیل» (elephant) inside «فیلم».
        'فیلم': RoomTopic.movies,
        // «art» inside "party", "car" inside "scary".
        'Partygoers': null,
        'Scary stories': null,
        // «پیک» (courier) is not «پیک‌نیک».
        'پیک‌نیک خانوادگی': RoomTopic.picnic,
      });
    });

    test('names that say nothing get no topic', () {
      expectTopics({
        '': null,
        '   ': null,
        'سپیدار': null,
        'Iron Riders': RoomTopic.motorcycle,
        'Crimson Arrows': null,
        'XQZ': null,
        '1234': null,
      });
    });
  });

  test('most suggested names have a topic', () {
    // Creation fills the field with one of these, so they are the names
    // people see most. Every curated one should read as something.
    for (final language in ['en', 'fa']) {
      final names = [
        ...RoomNameSuggester.namesFor(language),
        ...RoomNameSuggester.namesFor(language, ownerName: 'Pedram'),
      ];
      final unmatched = [
        for (final name in names)
          if (RoomTopicMatcher.match(name) == null) name,
      ];
      expect(
        unmatched.length,
        lessThanOrEqualTo(names.length ~/ 8),
        reason: '$language unmatched: $unmatched',
      );
    }
  });

  test('every topic is reachable from some name', () {
    // Guards the order: a topic that an earlier one always shadows would
    // never be shown.
    final reached = <RoomTopic>{};
    for (final name in _oneNamePerTopic) {
      final topic = RoomTopicMatcher.match(name);
      if (topic != null) reached.add(topic);
    }
    expect(RoomTopic.values.toSet().difference(reached), isEmpty);
  });

  test('is fast enough to call from build', () {
    final names = [for (var i = 0; i < 2000; i++) 'اکیپ کوهنوردی شماره $i'];
    final watch = Stopwatch()..start();
    for (final name in names) {
      RoomTopicMatcher.match(name);
    }
    watch.stop();
    // 2000 uncached names in well under a frame budget per name.
    expect(watch.elapsedMilliseconds / names.length, lessThan(1));
    // And a remembered one is the same answer.
    expect(RoomTopicMatcher.match(names.last), RoomTopic.hiking);
  });

  test('remembers a bounded number of names', () {
    for (var i = 0; i < 1000; i++) {
      RoomTopicMatcher.match('room $i');
    }
    expect(RoomTopicMatcher.match('کوه'), RoomTopic.hiking);
    expect(RoomTopicMatcher.match('room 1'), isNull);
  });
}

/// One name per topic, in [RoomTopic] order.
const _oneNamePerTopic = [
  'اورژانس',
  'آتش‌نشانی',
  'پلیس',
  'بیمارستان',
  'سربازی',
  'ترحیم',
  'مسجد',
  'کلیسا',
  'کنیسه',
  'عروسی',
  'تولد',
  'نوزاد',
  'راگبی',
  'فوتبال',
  'بسکتبال',
  'والیبال',
  'تنیس',
  'بیسبال',
  'کریکت',
  'هندبال',
  'هاکی',
  'گلف',
  'بوکس',
  'کاراته',
  'بدنسازی',
  'یوگا',
  'ماراتن',
  'پیاده‌روی',
  'شنا',
  'غواصی',
  'موج‌سواری',
  'کایاک',
  'قایق',
  'ماهیگیری',
  'پاراگلایدر',
  'اسنوبرد',
  'اسکی',
  'اسکیت‌برد',
  'پاتیناژ',
  'گرگ‌ها',
  'کوه',
  'کمپ',
  'پارک',
  'ساحل',
  'کویر',
  'باربری',
  'دوچرخه',
  'موتور',
  'دریفت',
  'آفرود',
  'ماشین',
  'تاکسی',
  'اتوبوس',
  'قطار',
  'مترو',
  'پرواز',
  'تور',
  'هتل',
  'سفر',
  'شطرنج',
  'تئاتر',
  'گیمرها',
  'مسابقات',
  'ورزش',
  'موسیقی',
  'عکاسی',
  'سینما',
  'کتاب',
  'کنکور',
  'دانشگاه',
  'مدرسه',
  'برنامه‌نویسی',
  'آزمایشگاه',
  'همکاران',
  'مغازه',
  'خرید',
  'پیمانکاری',
  'نقاشی',
  'کارخانه',
  'مزرعه',
  'باغچه',
  'کباب',
  'پیتزا',
  'کافه',
  'شام',
  'قلیان',
  'دورهمی',
  'همایش',
  'خیریه',
  'گربه',
  'خانواده',
  'عشق',
  'خونه',
  'همسایه‌ها',
  'رادیو',
  'پژواک',
  'طوفان',
  'رعد',
  'برف',
  'آتش',
  'باد',
  'غروب',
  'ستاره',
  'فضا',
  'شب',
  'آسمان',
  'جاده',
  'رفقا',
];
