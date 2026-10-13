// Expected extract.js results per fixture: dotted paths into the result object.
const CASES = {
  priority: {
    "isReference": true,
    "date": "2015/12",                        // citation_publication_date beats an earlier dc.date
    "publisher": "Springer US",               // citation_publisher beats dc.publisher
    "doi": "10.1007/s11263-015-0816-y",       // found in the second dc.identifier too
    "authors": ["Russakovsky, Olga", "Deng, Jia"],
    "pages": "211-252",
    "type": "journalArticle",
    "pdfUrl": location.origin + "/content/pdf/10.1007/s11263-015-0816-y.pdf",
  },
  sciencedirect: {
    "isReference": true,
    "doi": "10.1016/j.neunet.2014.09.003",    // the header link, not the references
    "title": "Deep learning in neural networks: An overview",
    "candidates": null,
  },
  coins: {
    "isReference": true,
    "title": "Attention Is All You Need",
    "authors": ["Vaswani, Ashish", "Shazeer, Noam"],
    "doi": "10.48550/arXiv.1706.03762",
    "venue": "Advances in Neural Information Processing Systems",
    "type": "journalArticle",
  },
  jsonld: {
    "isReference": true,
    "title": "Segment Anything",
    "authors": ["Alexander Kirillov", "Mintun, Eric"],
    "doi": "10.1109/ICCV51070.2023.00371",
    "date": "2023-04-05",
  },
  cnki: {
    "isReference": true,
    "doi": "10.13328/j.cnki.jos.006666",       // "DOI：" label in the page text
    "title": "基于深度学习的视网膜血管分割方法",
  },
  results: {
    "isReference": false,
    "candidates.length": 3,                    // the link without an identifier is skipped; PDF/arXiv duplicates merge
    "candidates.0.identifier": "10.1145/3292500.3330701",
    "candidates.0.title": "A Very Long Title About Graph Neural Networks for Things",
    "candidates.1.identifier": "10.1007/s11263-015-0816-y",
    "candidates.2.identifier": "2312.00752",
    "candidates.2.kind": "arXiv",
    "candidates.2.title": "Mamba: Linear-Time Sequence Modeling with Selective State Spaces",
  },
  blog: {
    "isReference": false,
    "title": "My reading notes",
    "candidates": null,
    "doi": "",
  },
  pdfviewer: {
    "isPDF": true,
    "title": "paper",
  },
};
