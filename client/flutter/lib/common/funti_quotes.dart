// FUNTIDESK: quotes for "About" (owner's idea 2026-10-08, approved
// 2026-10-11): about code and about people being connected. Only quotes with
// a known source; Russian is a short translation of the original.

class FuntiQuote {
  const FuntiQuote(this.ru, this.en, this.authorRu, this.authorEn);

  final String ru;
  final String en;
  final String authorRu;
  final String authorEn;
}

const List<FuntiQuote> kFuntiQuotes = [
  // EWD498, 1975.
  FuntiQuote('Простота — необходимое условие надёжности.',
      'Simplicity is prerequisite for reliability.',
      'Эдсгер Дейкстра', 'Edsger W. Dijkstra'),
  // "Computing Machinery and Intelligence", 1950.
  FuntiQuote(
      'Мы видим лишь недалеко вперёд, но видим, что там многое предстоит сделать.',
      'We can only see a short distance ahead, but we can see plenty there that needs to be done.',
      'Алан Тьюринг',
      'Alan Turing'),
  // Notes on the Analytical Engine, 1843.
  FuntiQuote(
      'Аналитическая машина ткёт алгебраические узоры, как жаккардов станок — цветы и листья.',
      'The Analytical Engine weaves algebraic patterns just as the Jacquard loom weaves flowers and leaves.',
      'Ада Лавлейс',
      'Ada Lovelace'),
  // Turing Award lecture, 1980.
  FuntiQuote(
      'Есть два способа построить программу: сделать её настолько простой, что в ней очевидно нет ошибок, или настолько сложной, что в ней нет очевидных ошибок.',
      'There are two ways of constructing a software design: make it so simple that there are obviously no deficiencies, or so complicated that there are no obvious deficiencies.',
      'Тони Хоар',
      'C. A. R. Hoare'),
  // "Structure and Interpretation of Computer Programs", 1985.
  FuntiQuote(
      'Программы пишутся для того, чтобы их читали люди, и лишь между делом — чтобы их исполняли машины.',
      'Programs must be written for people to read, and only incidentally for machines to execute.',
      'Харольд Абельсон и Джеральд Сассман',
      'Harold Abelson and Gerald Jay Sussman'),
  // "The Elements of Programming Style", 1978.
  FuntiQuote('Отлаживать программу вдвое труднее, чем написать её.',
      'Everyone knows that debugging is twice as hard as writing a program in the first place.',
      'Брайан Керниган', 'Brian Kernighan'),
  // "Terre des hommes", 1939.
  FuntiQuote(
      'Совершенство достигается не тогда, когда нечего добавить, а когда нечего убрать.',
      'Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away.',
      'Антуан де Сент-Экзюпери',
      'Antoine de Saint-Exupéry'),
  // "Terre des hommes", 1939.
  FuntiQuote(
      'Единственная настоящая роскошь — это роскошь человеческого общения.',
      'The only true luxury is that of human relationships.',
      'Антуан де Сент-Экзюпери',
      'Antoine de Saint-Exupéry'),
  // "Le Petit Prince", 1943.
  FuntiQuote('Зорко одно лишь сердце. Самого главного глазами не увидишь.',
      'One sees clearly only with the heart. What is essential is invisible to the eye.',
      'Антуан де Сент-Экзюпери', 'Antoine de Saint-Exupéry'),
  // "Le Petit Prince", 1943.
  FuntiQuote('Ты навсегда в ответе за всех, кого приручил.',
      'You become responsible, forever, for what you have tamed.',
      'Антуан де Сент-Экзюпери', 'Antoine de Saint-Exupéry'),
  // "Devotions upon Emergent Occasions", 1624.
  FuntiQuote('Нет человека, который был бы как остров, сам по себе.',
      'No man is an island, entire of itself.', 'Джон Донн', 'John Donne'),
  // "Politics".
  FuntiQuote('Человек по природе своей — существо общественное.',
      'Man is by nature a social animal.', 'Аристотель', 'Aristotle'),
  // Letter to his brother Alexander, 1889.
  FuntiQuote('Краткость — сестра таланта.', 'Brevity is the sister of talent.',
      'Антон Чехов', 'Anton Chekhov'),
  // linux-kernel mailing list, 2000.
  FuntiQuote('Слова ничего не стоят. Покажите мне код.',
      'Talk is cheap. Show me the code.', 'Линус Торвальдс', 'Linus Torvalds'),
  // "Refactoring", 1999.
  FuntiQuote(
      'Любой дурак напишет код, понятный компьютеру. Хорошие программисты пишут код, понятный людям.',
      'Any fool can write code that a computer can understand. Good programmers write code that humans can understand.',
      'Мартин Фаулер',
      'Martin Fowler'),
  // "The Mythical Man-Month", 1975.
  FuntiQuote('Если проект опаздывает, новые люди задержат его ещё сильнее.',
      'Adding manpower to a late software project makes it later.',
      'Фредерик Брукс', 'Frederick P. Brooks'),
  // Xerox PARC, 1971.
  FuntiQuote('Лучший способ предсказать будущее — изобрести его.',
      'The best way to predict the future is to invent it.', 'Алан Кэй',
      'Alan Kay'),
  // "Computer Programming as an Art", 1974.
  FuntiQuote('Преждевременная оптимизация — корень всех зол.',
      'Premature optimization is the root of all evil.', 'Дональд Кнут',
      'Donald Knuth'),
  // His blackboard at Caltech, 1988.
  FuntiQuote('Чего я не могу создать, того я не понимаю.',
      'What I cannot create, I do not understand.', 'Ричард Фейнман',
      'Richard Feynman'),
  // "Weaving the Web", 1999.
  FuntiQuote('Веб — скорее социальное творение, чем техническое.',
      'The Web is more a social creation than a technical one.',
      'Тим Бернерс-Ли', 'Tim Berners-Lee'),
  // Interview, Chips Ahoy magazine, 1986.
  FuntiQuote('Проще попросить прощения, чем получить разрешение.',
      "It's easier to ask forgiveness than it is to get permission.",
      'Грейс Хоппер', 'Grace Hopper'),
];
