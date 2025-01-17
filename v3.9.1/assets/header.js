
// We add a simple `onload` hook to inject the custom header for our `HTML`-generated pages
window.onload = function() {
    // <header class="navigation">
    const header = document.createElement('header')
    header.classList.add("navigation")
    header.appendChild((() => {
        const container = document.createElement('div')
        container.classList.add('container')
        container.appendChild((() => {
            const nav = document.createElement('nav')
            nav.classList.add("navbar")

            nav.appendChild((() => {
                const ul = document.createElement("ul")
                ul.classList.add("navbar-nav")

                ul.appendChild((() => {
                    const smalllink = document.createElement('li')
                    smalllink.classList.add('small-item')
                    smalllink.appendChild((() => {
                        const a = document.createElement('a')
                        a.classList.add("nav-link")
                        a.href = 'http://www.rxinfer.ml'
                        a.innerHTML = 'RxInfer.jl'
                        a.title = 'RxInfer.jl'
                        return a
                    })())
                    return smalllink
                })())

                const items = [
                    { title: "Home", link: "http://www.rxinfer.ml", icon: [ "fas", "fa-diagram-project" ] },
                    { title: "Get Started", link: "https://reactivebayes.github.io/RxInfer.jl/stable/manuals/getting-started/", icon: [ "fas", "fa-person-chalkboard" ] },
                    { title: "Documentation", link: "https://reactivebayes.github.io/RxInfer.jl/stable/", icon: [ "fas", "fa-book" ] },
                    { title: "Examples", link: "https://reactivebayes.github.io/RxInferExamples.jl/", icon: [ "fas", "fa-laptop-code" ] },
                    { title: "Papers", link: "https://biaslab.github.io/publication/", icon: [ "far", "fa-book-open" ] },
                    { title: "Team", link: "https://github.com/orgs/ReactiveBayes/people", icon: [ "fas", "fa-people-group" ] },
                    { title: "Discussions", link: "https://github.com/orgs/ReactiveBayes/discussions", icon: [ "far", "fa-comment" ] },
                    // { title: "Contact", link: "http://www.rxinfer.ml/contact/" }, the redirect is broken for now
                    { title: "GitHub", link: "https://github.com/reactivebayes/RxInfer.jl", icon: [ "fab", "fa-github" ] },
                ]

                items.forEach((item) => {
                    ul.appendChild(((item) => {
                        const li = document.createElement("li")
                        li.classList.add("nav-item")
                        li.appendChild((() => {
                            const a = document.createElement("a")

                            if (item.icon !== undefined) {
                                a.appendChild((() => {
                                    const i = document.createElement("i")
                                    i.classList.add(...(item.icon))
                                    return i    
                                })())
                            }

                            a.classList.add("nav-link")
                            a.href = item.link
                            a.title = item.title

                            a.appendChild((() => {
                                const span = document.createElement("span")
                                span.innerHTML = `&nbsp;${item.title}`
                                return span
                            })())

                            return a
                        })())
                        return li
                    })(item))
                })
                return ul
            })())
            return nav
        })())
        return container
    })())
    
    const documenterTarget = document.querySelector('#documenter');
    
    documenterTarget.parentNode.insertBefore(header, documenterTarget);
}

