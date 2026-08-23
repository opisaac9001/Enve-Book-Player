package com.enve.app.data.reader

class ReaderNavigationHistory(
    private val maxEntries: Int = 100,
) {
    private val backStack = ArrayDeque<String>()
    private val forwardStack = ArrayDeque<String>()

    val canGoBack: Boolean get() = backStack.isNotEmpty()
    val canGoForward: Boolean get() = forwardStack.isNotEmpty()

    fun recordJumpOrigin(locatorJson: String?) {
        val normalized = locatorJson?.takeIf { it.isNotBlank() } ?: return
        if (backStack.lastOrNull() == normalized) return
        backStack.addLast(normalized)
        while (backStack.size > maxEntries) {
            backStack.removeFirst()
        }
        forwardStack.clear()
    }

    fun backTarget(): String? = backStack.lastOrNull()

    fun forwardTarget(): String? = forwardStack.lastOrNull()

    fun commitBack(currentLocatorJson: String?) {
        val target = backStack.removeLastOrNull() ?: return
        currentLocatorJson
            ?.takeIf { it.isNotBlank() && it != target }
            ?.let { forwardStack.addLast(it) }
    }

    fun commitForward(currentLocatorJson: String?) {
        val target = forwardStack.removeLastOrNull() ?: return
        currentLocatorJson
            ?.takeIf { it.isNotBlank() && it != target }
            ?.let { backStack.addLast(it) }
    }
}
