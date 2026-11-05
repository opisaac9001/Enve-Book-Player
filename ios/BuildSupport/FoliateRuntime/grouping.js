export const groupMap = (items, keyFor) => {
    const groups = new Map()
    for (const item of items) {
        const key = keyFor(item)
        const group = groups.get(key)
        if (group) group.push(item)
        else groups.set(key, [item])
    }
    return groups
}

export const groupObject = (items, keyFor) => {
    const groups = Object.create(null)
    for (const [key, values] of groupMap(items, item => String(keyFor(item)))) groups[key] = values
    return groups
}
