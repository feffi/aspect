---
layout: page
title: Filters › keys
---

[← filters](./../filters.md)

<!-- {% raw %} -->

Filter: `keys`:
* no args

---

The `keys` filter returns the keys of an array. 
It is useful when you want to iterate over the keys of an array:

```twig
{% for key in array|keys %}
    ...
{% endfor %}
```

<!-- {% endraw %} -->