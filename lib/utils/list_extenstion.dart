extension ListExtenstion on List {
  bool listsHaveSameElements(List b) {
    if (length != b.length) return false;
    List sortedA = List.from(this)..sort();
    List sortedB = List.from(b)..sort();
    for (int i = 0; i < sortedA.length; i++) {
      if (sortedA[i] != sortedB[i]) return false;
    }
    return true;
  }

  bool containsAllElements(List other) {
    for (var element in other) {
      if (!contains(element)) return false;
    }
    return true;
  }
}
