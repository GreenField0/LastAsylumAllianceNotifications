document.addEventListener('DOMContentLoaded', () => {
    // --- Configuration ---
    const GUIDES_DIR = 'guides/';
    const userLang = navigator.language || navigator.userLanguage;
    const detectedLang = userLang.toLowerCase().startsWith('de') ? 'de' : 'en';
    const DEFAULT_LANG = localStorage.getItem('lang') || detectedLang;

    // The navigation mapping for both languages
    const navigation = {
        de: [
            { id: 'ALLIANZ-ZEITPLAN', title: '📅 Zeitplan', file: 'ALLIANZ-ZEITPLAN.md' },
            { id: 'ALLIANZ_REGELN', title: '📜 Regeln & SvS', file: 'ALLIANZ_REGELN.md' },
            { id: 'HELDEN_GUIDE', title: '🦸 Helden', file: 'HELDEN_GUIDE.md' },
            { id: 'RABEN_GUIDE', title: '🦅 Raben', file: 'RABEN_GUIDE.md' },
            { id: 'ANFAENGER_TIPPS', title: '💎 Tipps', file: 'ANFAENGER_TIPPS.md' },
            { id: 'GIFT_CODES', title: '🎁 Gift Codes', file: 'GIFT_CODES.md' }
        ],
        en: [
            { id: 'SCHEDULE_en', title: '📅 Schedule', file: 'SCHEDULE_en.md' },
            { id: 'ALLIANCE_RULES_en', title: '📜 Rules & SvS', file: 'ALLIANCE_RULES_en.md' },
            { id: 'HEROES_GUIDE_en', title: '🦸 Heroes', file: 'HEROES_GUIDE_en.md' },
            { id: 'RAVENS_GUIDE_en', title: '🦅 Ravens', file: 'RAVENS_GUIDE_en.md' },
            { id: 'BEGINNER_TIPS_en', title: '💎 Tips', file: 'BEGINNER_TIPS_en.md' },
            { id: 'GIFT_CODES_en', title: '🎁 Gift Codes', file: 'GIFT_CODES_en.md' }
        ]
    };

    // --- State ---
    let currentLang = DEFAULT_LANG;
    let currentDocId = ''; // will be set on load

    // --- DOM Elements ---
    const navList = document.getElementById('nav-list');
    const contentDiv = document.getElementById('content');
    const btnDe = document.getElementById('lang-de');
    const btnEn = document.getElementById('lang-en');
    const tzInfo = document.getElementById('tz-info');
    const mobileMenuBtn = document.getElementById('mobile-menu-btn');
    const sidebar = document.getElementById('sidebar');

    // --- Init ---
    initTimezone();
    setLanguage(currentLang);

    // --- Event Listeners ---
    btnDe.addEventListener('click', () => setLanguage('de'));
    btnEn.addEventListener('click', () => setLanguage('en'));
    mobileMenuBtn.addEventListener('click', () => {
        sidebar.classList.toggle('active');
    });

    // --- Core Functions ---
    function setLanguage(lang) {
        currentLang = lang;
        localStorage.setItem('lang', lang);
        
        // Update Buttons
        btnDe.classList.toggle('active', lang === 'de');
        btnEn.classList.toggle('active', lang === 'en');

        // Render Nav
        renderNav();

        // Find the equivalent document in the new language or fallback to the first one
        let newDocToLoad = navigation[lang][0].id;
        
        // Very basic mapping (index based for simplicity)
        const oldIndex = currentLang === 'de' ? 
            navigation.en.findIndex(n => n.id === currentDocId) : 
            navigation.de.findIndex(n => n.id === currentDocId);
            
        if (oldIndex !== -1) {
             newDocToLoad = navigation[lang][oldIndex].id;
        }

        loadDocument(newDocToLoad);
    }

    function renderNav() {
        navList.innerHTML = '';
        navigation[currentLang].forEach(item => {
            const li = document.createElement('li');
            const a = document.createElement('a');
            a.href = '#' + item.id;
            a.textContent = item.title;
            a.dataset.id = item.id;
            
            a.addEventListener('click', (e) => {
                e.preventDefault();
                loadDocument(item.id);
                if (window.innerWidth <= 900) {
                    sidebar.classList.remove('active'); // close mobile menu on click
                }
            });
            
            li.appendChild(a);
            navList.appendChild(li);
        });
    }

    function loadDocument(docId) {
        currentDocId = docId;
        
        // Update active class in Nav
        document.querySelectorAll('.nav-links a').forEach(a => {
            a.classList.toggle('active', a.dataset.id === docId);
        });

        // Find the file
        const item = navigation[currentLang].find(i => i.id === docId);
        if (!item) return;

        contentDiv.innerHTML = '<div class="loader">Loading...</div>';

        fetch(GUIDES_DIR + item.file)
            .then(response => {
                if (!response.ok) throw new Error('Network response was not ok');
                return response.text();
            })
            .then(markdown => {
                // Strip the static navigation header from markdown files (since we have the sidebar now)
                let cleanMarkdown = markdown.replace(/^> 🌐 \*\*Language.*\n/m, '');
                cleanMarkdown = cleanMarkdown.replace(/^> 📌 \*\*Navigation.*\n/m, '');
                
                // Parse markdown to HTML
                let html = marked.parse(cleanMarkdown);
                
                // Render
                contentDiv.innerHTML = html;
                
                // Post-process: Convert Timezones
                processTimezones();
            })
            .catch(error => {
                console.error('Error loading markdown:', error);
                contentDiv.innerHTML = `<h2>⚠️ Error</h2><p>Could not load the guide. ${error.message}</p>`;
            });
    }

    function initTimezone() {
        try {
            const userTZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
            const formatter = new Intl.DateTimeFormat(navigator.language || 'en-US', {
                timeZoneName: 'short'
            });
            const parts = formatter.formatToParts(new Date());
            const tzName = parts.find(p => p.type === 'timeZoneName')?.value || '';
            tzInfo.textContent = `Local Timezone: ${userTZ} (${tzName})`;
        } catch (e) {
            tzInfo.textContent = "Local Timezone detected automatically";
        }
    }

    function processTimezones() {
        // We will look for elements like: <span data-time="02:00">02:00</span>
        // or just parse the whole HTML for a specific format if we prefer, but data-time is safer.
        const timeElements = document.querySelectorAll('span[data-time]');
        
        if (timeElements.length === 0) {
             // Fallback: Use Regex to find standard UTC times in the text and convert them!
             // E.g. replacing "02:00 UTC" to local time. This is more resilient if Eike forgets the span tags.
             convertTextNodes(contentDiv);
        } else {
            timeElements.forEach(el => {
                const utcTimeStr = el.getAttribute('data-time'); // e.g. "04:00"
                el.textContent = convertUtcTimeToLocal(utcTimeStr);
                el.classList.add('local-time');
                el.title = `Converted from ${utcTimeStr} UTC`;
            });
        }
    }

    function convertTextNodes(node) {
        // This is a powerful fallback: automatically find "HH:MM UTC" in ANY text node and replace it with local time!
        if (node.nodeType === Node.TEXT_NODE) {
            // Regex to match "02:00 UTC" or "14:00 UTC"
            const regex = /\b([0-1][0-9]|2[0-3]):([0-5][0-9])\s*(UTC)\b/g;
            if (regex.test(node.nodeValue)) {
                const spanWrap = document.createElement('span');
                let htmlString = node.nodeValue.replace(regex, (match, hh, mm) => {
                    const localStr = convertUtcTimeToLocal(`${hh}:${mm}`);
                    return `<span class="local-time" title="Converted from ${match}">${localStr}</span>`;
                });
                
                // Since replace doesn't return DOM nodes but strings, we replace the text node with a span
                // Only if there was a replacement
                if (htmlString !== node.nodeValue) {
                    const tempDiv = document.createElement('div');
                    tempDiv.innerHTML = htmlString;
                    while (tempDiv.firstChild) {
                        node.parentNode.insertBefore(tempDiv.firstChild, node);
                    }
                    node.parentNode.removeChild(node);
                }
            }
        } else if (node.nodeType === Node.ELEMENT_NODE && node.nodeName !== 'SCRIPT' && node.nodeName !== 'STYLE') {
            // Loop backwards because we might modify the DOM (add nodes)
            for (let i = node.childNodes.length - 1; i >= 0; i--) {
                convertTextNodes(node.childNodes[i]);
            }
        }
    }

    function convertUtcTimeToLocal(timeStr) {
        // timeStr is like "02:00"
        const [hours, minutes] = timeStr.split(':').map(Number);
        
        // Create a date object in UTC for TODAY
        const date = new Date();
        date.setUTCHours(hours, minutes, 0, 0);
        
        // Format to local time
        return new Intl.DateTimeFormat(navigator.language || 'en-US', {
            hour: '2-digit',
            minute: '2-digit'
        }).format(date);
    }
});
