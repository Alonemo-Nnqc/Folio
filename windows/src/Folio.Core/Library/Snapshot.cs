using Microsoft.Data.Sqlite;
using static Folio.Core.AppDatabase;
using static Folio.Core.Records;

namespace Folio.Core;

/// <summary>Preset tag colours. Grey is the default for imported tags.</summary>
public static class TagPalette
{
    public static readonly (string Name, string Hex)[] Presets =
    [
        ("红", "#FF3B30"), ("橙", "#FF9500"), ("黄", "#FFCC00"), ("绿", "#34C759"), ("薄荷", "#00C7BE"),
        ("青", "#32ADE6"), ("蓝", "#007AFF"), ("靛", "#5856D6"), ("紫", "#AF52DE"), ("粉", "#FF2D55"),
    ];

    public const string ImportDefault = "#8E8E93";
}

/// <summary>An immutable, fully-loaded view of the library, rebuilt whenever the database changes.</summary>
public sealed class LibrarySnapshot
{
    public Dictionary<string, Item> Items { get; } = [];
    public Dictionary<string, FileRecord> Files { get; } = [];
    /// <summary>File ids per item, oldest first.</summary>
    public Dictionary<string, List<string>> FilesByItem { get; } = [];
    public Dictionary<string, LibraryGroup> GroupsById { get; } = [];
    /// <summary>Top-level group ids in display order.</summary>
    public List<string> TopLevelGroups { get; } = [];
    /// <summary>Child group ids per parent, in display order.</summary>
    public Dictionary<string, List<string>> ChildGroups { get; } = [];
    /// <summary>Direct members per group.</summary>
    public Dictionary<string, HashSet<string>> GroupItems { get; } = [];
    public Dictionary<string, HashSet<string>> ItemGroups { get; } = [];
    /// <summary>Tags in display order.</summary>
    public List<Tag> Tags { get; } = [];
    public Dictionary<string, Tag> TagsById { get; } = [];
    /// <summary>Tag ids per item, in tag display order.</summary>
    public Dictionary<string, List<string>> ItemTags { get; } = [];
    public Dictionary<string, HashSet<string>> TagItems { get; } = [];
    /// <summary>Custom order positions: scope key → item id → position.</summary>
    public Dictionary<string, Dictionary<string, double>> Orders { get; } = [];
    public Dictionary<string, SortState> Sorts { get; } = [];
    public HashSet<string> NotedItems { get; } = [];
    /// <summary>Lowercased text each item is searched against.</summary>
    public Dictionary<string, string> SearchText { get; } = [];
    /// <summary>easyScholar ranks per journal (JournalMetrics.Key), including journals it does not list (META-30).</summary>
    public Dictionary<string, JournalMetrics> JournalMetrics { get; } = [];

    /// <summary>The cached ranks of an item's journal, if it has a journal and they were fetched.</summary>
    public JournalMetrics? JournalMetricsOf(Item item) =>
        Folio.Core.JournalMetrics.JournalName(item) is { } name ? JournalMetrics.GetValueOrDefault(Folio.Core.JournalMetrics.Key(name)) : null;

    public static readonly LibrarySnapshot Empty = new();

    public SortState Sort(ViewScope scope) => Sorts.GetValueOrDefault(scope.Key) ?? SortState.Manual;

    public List<FileRecord> FilesOf(string itemId) =>
        FilesByItem.TryGetValue(itemId, out var ids) ? ids.Select(id => Files[id]).ToList() : [];

    public List<Tag> TagsOf(string itemId) =>
        ItemTags.TryGetValue(itemId, out var ids) ? ids.Where(TagsById.ContainsKey).Select(id => TagsById[id]).ToList() : [];

    // MARK: Group hierarchy (SIDE-17)

    /// <summary>The group followed by all its descendants, depth first in display order.</summary>
    public List<string> GroupAndDescendants(string groupId) => [groupId, .. GroupDescendants(groupId)];

    /// <summary>All descendants of a group (not the group itself), depth first in display order.</summary>
    public List<string> GroupDescendants(string groupId)
    {
        var result = new List<string>();
        var seen = new HashSet<string> { groupId };
        void Visit(string id)
        {
            foreach (var child in ChildGroups.GetValueOrDefault(id) ?? [])
                if (seen.Add(child)) { result.Add(child); Visit(child); }
        }
        Visit(groupId);
        return result;
    }

    /// <summary>Ancestor ids from the top level down, not including the group itself.</summary>
    public List<string> GroupAncestors(string groupId)
    {
        var chain = new List<string>();
        var seen = new HashSet<string> { groupId };
        var current = GroupsById.GetValueOrDefault(groupId)?.ParentId;
        while (current != null && seen.Add(current) && GroupsById.TryGetValue(current, out var group))
        {
            chain.Insert(0, current);
            current = group.ParentId;
        }
        return chain;
    }

    /// <summary>The group's level: 1 for a top-level group.</summary>
    public int GroupDepth(string groupId) => GroupAncestors(groupId).Count + 1;

    /// <summary>How many levels the group and its subtree span: 1 for a group without subgroups.</summary>
    public int GroupSubtreeHeight(string groupId)
    {
        var seen = new HashSet<string> { groupId };
        int Height(string id) => 1 + (ChildGroups.GetValueOrDefault(id) ?? []).Where(seen.Add).ToList().Select(Height).DefaultIfEmpty(0).Max();
        return Height(groupId);
    }

    /// <summary>Names from the top-level ancestor down to the group.</summary>
    public List<string> GroupPath(string groupId) =>
        [.. GroupAncestors(groupId).Append(groupId).Where(GroupsById.ContainsKey).Select(id => GroupsById[id].Name)];

    /// <summary>Whether a new subgroup may be created inside the group.</summary>
    public bool CanAddSubgroup(string groupId) => GroupsById.ContainsKey(groupId) && GroupDepth(groupId) < LibraryGroup.MaximumDepth;

    /// <summary>Whether the group (with its subtree) may move under parentId (null = top level): not into itself or a
    /// descendant, and no deeper than <see cref="LibraryGroup.MaximumDepth"/> levels.</summary>
    public bool CanMoveGroup(string groupId, string? parentId)
    {
        if (!GroupsById.ContainsKey(groupId)) return false;
        if (parentId == null) return true;
        if (parentId == groupId || !GroupsById.ContainsKey(parentId) || GroupAncestors(parentId).Contains(groupId)) return false;
        return GroupDepth(parentId) + GroupSubtreeHeight(groupId) <= LibraryGroup.MaximumDepth;
    }

    /// <summary>Groups in sidebar order, each followed by its subgroups, with their depth (0 = top level; for menus).</summary>
    public IEnumerable<(LibraryGroup Group, int Depth)> GroupsForMenus()
    {
        var result = new List<(LibraryGroup, int)>();
        var seen = new HashSet<string>();
        void Visit(IEnumerable<string> ids, int depth)
        {
            foreach (var id in ids)
            {
                if (!seen.Add(id) || !GroupsById.TryGetValue(id, out var group)) continue;
                result.Add((group, depth));
                Visit(ChildGroups.GetValueOrDefault(id) ?? [], depth + 1);
            }
        }
        Visit(TopLevelGroups, 0);
        return result;
    }

    internal static LibrarySnapshot Fetch(SqliteConnection c)
    {
        var s = new LibrarySnapshot();
        foreach (var item in Query(c, null, "SELECT * FROM item", ReadItem)) s.Items[item.Id] = item;
        foreach (var file in Query(c, null, "SELECT * FROM file ORDER BY dateAdded, id", ReadFile))
        {
            s.Files[file.Id] = file;
            (s.FilesByItem.TryGetValue(file.ItemId, out var list) ? list : s.FilesByItem[file.ItemId] = []).Add(file.Id);
        }
        foreach (var group in Query(c, null, "SELECT * FROM libraryGroup ORDER BY position, name", ReadGroup))
        {
            s.GroupsById[group.Id] = group;
            if (group.ParentId is { } parent) (s.ChildGroups.TryGetValue(parent, out var l) ? l : s.ChildGroups[parent] = []).Add(group.Id);
            else s.TopLevelGroups.Add(group.Id);
        }
        foreach (var (itemId, groupId) in Query(c, null, "SELECT itemId, groupId FROM itemGroup", r => (r.GetString(0), r.GetString(1))))
        {
            (s.GroupItems.TryGetValue(groupId, out var a) ? a : s.GroupItems[groupId] = []).Add(itemId);
            (s.ItemGroups.TryGetValue(itemId, out var b) ? b : s.ItemGroups[itemId] = []).Add(groupId);
        }
        s.Tags.AddRange(Query(c, null, "SELECT * FROM tag ORDER BY position, name", ReadTag));
        var rank = new Dictionary<string, int>();
        for (int i = 0; i < s.Tags.Count; i++) { s.TagsById[s.Tags[i].Id] = s.Tags[i]; rank[s.Tags[i].Id] = i; }
        foreach (var (itemId, tagId) in Query(c, null, "SELECT itemId, tagId FROM itemTag", r => (r.GetString(0), r.GetString(1))))
        {
            (s.ItemTags.TryGetValue(itemId, out var a) ? a : s.ItemTags[itemId] = []).Add(tagId);
            (s.TagItems.TryGetValue(tagId, out var b) ? b : s.TagItems[tagId] = []).Add(itemId);
        }
        foreach (var list in s.ItemTags.Values) list.Sort((x, y) => rank.GetValueOrDefault(x).CompareTo(rank.GetValueOrDefault(y)));
        foreach (var (scope, itemId, position) in Query(c, null, "SELECT scope, itemId, position FROM itemOrder", r => (r.GetString(0), r.GetString(1), r.GetDouble(2))))
            (s.Orders.TryGetValue(scope, out var d) ? d : s.Orders[scope] = [])[itemId] = position;
        foreach (var (scope, column, asc) in Query(c, null, "SELECT scope, sortColumn, ascending FROM viewSort", r => (r.GetString(0), r.IsDBNull(1) ? null : r.GetString(1), r.GetInt64(2) != 0)))
            s.Sorts[scope] = new SortState(SortColumns.Parse(column), asc);
        var notes = new Dictionary<string, string>();
        foreach (var (itemId, content) in Query(c, null, "SELECT itemId, content FROM note", r => (r.GetString(0), r.GetString(1))))
        {
            notes[itemId] = content;
            s.NotedItems.Add(itemId);
        }
        foreach (var (name, json, fetched) in Query(c, null, "SELECT name, json, fetchedAt FROM journalMetrics", r => (r.GetString(0), r.GetString(1), r.GetValue(2))))
            s.JournalMetrics[name] = Folio.Core.JournalMetrics.FromJson(json, fetched is DateTime d ? d : ParseDate(Convert.ToString(fetched, System.Globalization.CultureInfo.InvariantCulture)!));
        foreach (var item in s.Items.Values)
            s.SearchText[item.Id] = SearchMatcher.Haystack(item, s.TagsOf(item.Id), s.FilesOf(item.Id), notes.GetValueOrDefault(item.Id));
        return s;
    }
}

public sealed record ViewQuery(ViewScope Scope, string SearchText = "", bool SearchWholeLibrary = false,
                               IReadOnlySet<string>? FulltextItemIds = null, bool IncludeSubgroupItems = true, SortState? Sort = null)
{
    public bool IsSearching => SearchText.Trim().Length > 0;
}

/// <summary>Computes the ordered top-level rows of a view from a snapshot. Pure and fast.</summary>
public static class ViewResolver
{
    public static List<string> Members(ViewScope scope, LibrarySnapshot s, bool includeSubgroupItems) => scope switch
    {
        ViewScope.AllScope => s.Items.Values.Where(i => !i.IsTrashed).Select(i => i.Id).ToList(),
        ViewScope.UnfiledScope => s.Items.Values.Where(i => !i.IsTrashed && (!s.ItemGroups.TryGetValue(i.Id, out var g) || g.Count == 0)).Select(i => i.Id).ToList(),
        ViewScope.TrashScope => s.Items.Values.Where(i => i.IsTrashed).Select(i => i.Id).ToList(),
        ViewScope.GroupScope g => (includeSubgroupItems ? s.GroupAndDescendants(g.Id) : [g.Id])
            .SelectMany(id => s.GroupItems.GetValueOrDefault(id) ?? []).Distinct()
            .Where(id => s.Items.TryGetValue(id, out var i) && !i.IsTrashed).ToList(),
        ViewScope.TagScope t => (s.TagItems.GetValueOrDefault(t.Id) ?? []).Where(id => s.Items.TryGetValue(id, out var i) && !i.IsTrashed).ToList(),
        _ => [],
    };

    public static List<string> Rows(ViewQuery q, LibrarySnapshot s)
    {
        var effective = q.IsSearching && q.SearchWholeLibrary && q.Scope is not ViewScope.TrashScope ? ViewScope.All : q.Scope;
        var ids = Members(effective, s, q.IncludeSubgroupItems);
        if (q.IsSearching)
        {
            var tokens = SearchMatcher.Tokens(q.SearchText);
            var fulltext = q.FulltextItemIds ?? new HashSet<string>();
            ids = ids.Where(id => fulltext.Contains(id) || SearchMatcher.Matches(tokens, s.SearchText.GetValueOrDefault(id) ?? "")).ToList();
        }
        var items = ids.Select(id => s.Items[id]).ToList();
        var sort = q.Sort ?? SortState.Manual;
        if (sort.Column is { } column)
            items.Sort((a, b) => SortComparators.Compare(a, b, column, sort.Ascending, s));
        else if (effective is ViewScope.TrashScope)
            items.Sort((a, b) => b.TrashedAt != a.TrashedAt ? Nullable.Compare(b.TrashedAt, a.TrashedAt) : string.CompareOrdinal(b.Id, a.Id));
        else
        {
            var positions = s.Orders.GetValueOrDefault(effective.Key) ?? [];
            double Position(Item i) => positions.TryGetValue(i.Id, out var p) ? p : -(i.DateAdded - DateTime.UnixEpoch).TotalSeconds;
            items.Sort((a, b) =>
            {
                var (pa, pb) = (Position(a), Position(b));
                if (pa != pb) return pa.CompareTo(pb);
                if (a.DateAdded != b.DateAdded) return b.DateAdded.CompareTo(a.DateAdded);
                return string.CompareOrdinal(a.Id, b.Id);
            });
        }
        return items.Select(i => i.Id).ToList();
    }
}

/// <summary>Column sorting for the item list. Empty values always sort last, whatever the direction.</summary>
public static class SortComparators
{
    static readonly StringComparer Natural = StringComparer.Create(System.Globalization.CultureInfo.CurrentCulture,
        System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.NumericOrdering);

    static object? Key(SortColumn column, Item item, LibrarySnapshot s) => column switch
    {
        SortColumn.Title => item.Title,
        SortColumn.Authors => AuthorFormatter.ListDisplay(item.Authors),
        SortColumn.Year => (double?)item.Year,
        SortColumn.Source => item.Source,
        SortColumn.Type => item.Kind == ItemKind.Standalone ? null : item.Type.DisplayName(),
        SortColumn.DateAdded => (item.DateAdded - DateTime.UnixEpoch).TotalSeconds,
        SortColumn.DateModified => (item.DateModified - DateTime.UnixEpoch).TotalSeconds,
        SortColumn.Doi => item.Doi,
        SortColumn.Publisher => item.Publisher,
        SortColumn.Volume => item.Volume,
        SortColumn.Issue => item.Issue,
        SortColumn.Pages => item.Pages,
        SortColumn.ReadStatus => item.Kind == ItemKind.Standalone ? null : (double)(int)item.ReadStatus,
        SortColumn.Rating => item.Rating > 0 ? item.Rating : null,
        SortColumn.FileCount => (double)(s.FilesByItem.GetValueOrDefault(item.Id)?.Count ?? 0),
        SortColumn.CitationKey => item.CitationKey,
        SortColumn.Tags => s.TagsOf(item.Id).FirstOrDefault()?.Name,
        SortColumn.JournalRank => s.JournalMetricsOf(item)?.RankSortKey,
        SortColumn.ImpactFactor => s.JournalMetricsOf(item)?.ImpactFactor,
        _ => null,
    };

    static bool IsEmpty(object? key) => key switch { null => true, string str => str.Trim().Length == 0, _ => false };

    public static int Compare(Item a, Item b, SortColumn column, bool ascending, LibrarySnapshot s)
    {
        var ka = Key(column, a, s);
        var kb = Key(column, b, s);
        bool ea = IsEmpty(ka), eb = IsEmpty(kb);
        if (ea != eb) return ea ? 1 : -1;
        if (!ea)
        {
            int result = ka is string x && kb is string y ? Natural.Compare(x, y) : Convert.ToDouble(ka).CompareTo(Convert.ToDouble(kb));
            if (result != 0) return ascending ? result : -result;
        }
        int tie = Natural.Compare(a.Title, b.Title);
        return tie != 0 ? tie : string.CompareOrdinal(a.Id, b.Id);
    }
}

/// <summary>Item counts shown next to each sidebar entry.</summary>
public static class SidebarCounts
{
    public static Dictionary<string, int> Compute(LibrarySnapshot s, bool includeSubgroupItems)
    {
        var counts = new Dictionary<string, int>();
        foreach (var scope in new[] { ViewScope.All, ViewScope.Unfiled, ViewScope.Trash })
            counts[scope.Key] = ViewResolver.Members(scope, s, includeSubgroupItems).Count;
        foreach (var id in s.GroupsById.Keys) counts[ViewScope.Group(id).Key] = ViewResolver.Members(ViewScope.Group(id), s, includeSubgroupItems).Count;
        foreach (var tag in s.Tags) counts[ViewScope.TagOf(tag.Id).Key] = ViewResolver.Members(ViewScope.TagOf(tag.Id), s, includeSubgroupItems).Count;
        return counts;
    }
}
