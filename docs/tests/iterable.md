---
layout: page
title: Tests › iterable
---

[← tests](./../tests.md)

<!-- {% raw %} -->

`iterable` checks if a variable is an array or a traversable object:

```twig
{# evaluates to true if the foo variable is iterable #}
{% if users is iterable %}
    {% for user in users %}
        Hello {{ user }}!
    {% endfor %}
{% else %}
    {# users is probably a string #}
    Hello {{ users }}!
{% endif %}
```

<!-- {% endraw %} -->