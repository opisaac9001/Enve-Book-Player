import Foundation

enum ReaderWideContentScript {
    enum Result: Equatable {
        case changed
        case stable
        case blocked
        case failed
    }

    static let source = """
        (function (force) {
            var ATTR = 'data-enve-fit';
            var state = window.__enveWideContent || (window.__enveWideContent = {});
            if (state.measured && !force) return 'stable';
            var token = state.token || (state.token = 'w' + Math.random().toString(36).slice(2, 10));
            var table = 'table[' + ATTR + '="' + token + '"]';
            var pre = 'pre[' + ATTR + '="' + token + '"]';
            if (!state.style || !state.style.isConnected) {
                var style = document.createElement('style');
                style.textContent =
                    table + '{table-layout:fixed !important;width:100% !important;max-width:100% !important}' +
                    table + ' td,' + table + ' th{overflow-wrap:anywhere !important}' +
                    pre + '{white-space:pre-wrap !important;overflow-wrap:anywhere !important;max-width:100% !important}';
                (document.head || document.documentElement).appendChild(style);
                state.style = style;
                if (!style.sheet) return 'blocked';
            }
            function room(element) {
                var parent = element.parentElement;
                if (!parent) return 0;
                var computed = getComputedStyle(parent);
                return parent.clientWidth - parseFloat(computed.paddingLeft) - parseFloat(computed.paddingRight);
            }
            function widest(element) {
                var rects = element.getClientRects();
                var width = 0;
                for (var index = 0; index < rects.length; index += 1) {
                    if (rects[index].width > width) width = rects[index].width;
                }
                if (element.localName === 'pre') {
                    var range = document.createRange();
                    range.selectNodeContents(element);
                    for (var rect of range.getClientRects()) width = Math.max(width, rect.width);
                }
                return width;
            }
            function measure() {
                var changed = false;
                for (var pass = 0; pass < 3; pass += 1) {
                    var elements = document.querySelectorAll('table, pre');
                    var had = [];
                    var index;
                    for (index = 0; index < elements.length; index += 1) {
                        had.push(elements[index].getAttribute(ATTR) === token);
                        if (had[index]) elements[index].removeAttribute(ATTR);
                    }
                    var passChanged = false;
                    for (index = 0; index < elements.length; index += 1) {
                        var element = elements[index];
                        var available = room(element);
                        var wants = available > 0 && widest(element) > available + 1;
                        if (wants) element.setAttribute(ATTR, token);
                        if (wants !== had[index]) passChanged = true;
                    }
                    if (!passChanged) break;
                    changed = true;
                }
                return changed;
            }
            if (!state.resizeHooked) {
                state.resizeHooked = true;
                var frame = 0;
                window.addEventListener('resize', function () {
                    cancelAnimationFrame(frame);
                    frame = requestAnimationFrame(measure);
                });
            }
            state.measured = true;
            return measure() ? 'changed' : 'stable';
        })(false);
        """

    static var remeasure: String { source.replacingOccurrences(of: "})(false);", with: "})(true);") }

    static func parse(_ value: Any?) -> Result {
        switch (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "changed": .changed
        case "stable": .stable
        case "blocked": .blocked
        default: .failed
        }
    }
}
